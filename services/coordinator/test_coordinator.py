import importlib.util
import os
import tempfile
import unittest
import sys
from unittest.mock import patch
from pathlib import Path, PurePosixPath

os.environ.setdefault("QBITTORRENT_USERNAME", "test")
os.environ.setdefault("QBITTORRENT_PASSWORD", "test")
os.environ.setdefault("COORDINATOR_STATE_FILE", "/tmp/coordinator-test-state.json")
os.environ.setdefault("QBITTORRENT_COMPLETED_ROOT", "/data/downloads")
os.environ.setdefault("QBITTORRENT_SONARR_CATEGORY", "sonarr")
os.environ.setdefault("QBITTORRENT_SONARR_CATEGORY_PATH", "/data/downloads/tv")
os.environ.setdefault("QBITTORRENT_RADARR_CATEGORY", "radarr")
os.environ.setdefault("QBITTORRENT_RADARR_CATEGORY_PATH", "/data/downloads/movies")

SPEC = importlib.util.spec_from_file_location(
    "coordinator",
    Path(__file__).with_name("coordinator.py"),
)
coordinator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = coordinator
assert SPEC.loader is not None
SPEC.loader.exec_module(coordinator)

SONARR = next(target for target in coordinator.TARGETS if target.key == "sonarr")
RADARR = next(target for target in coordinator.TARGETS if target.key == "radarr")


class CoordinatorHelpersTest(unittest.TestCase):
    def test_validate_configuration(self):
        coordinator.validate_configuration()

    def test_qbit_login_accepts_legacy_200_when_followup_is_authenticated(self):
        with patch.object(
            coordinator,
            "request_bytes",
            side_effect=[(200, b"Ok.\n"), (200, b'{"auto_tmm_enabled": true}')],
        ) as request:
            coordinator.qbit_login()
            self.assertEqual(request.call_count, 2)

    def test_qbit_login_accepts_204_when_followup_is_authenticated(self):
        with patch.object(
            coordinator,
            "request_bytes",
            side_effect=[(204, b""), (200, b'{"auto_tmm_enabled": true}')],
        ) as request:
            coordinator.qbit_login()
            self.assertEqual(request.call_count, 2)

    def test_qbit_login_rejects_204_when_followup_is_unauthorized(self):
        with patch.object(
            coordinator,
            "request_bytes",
            side_effect=[(204, b""), (403, b"Forbidden")],
        ):
            with self.assertRaises(coordinator.QBitAuthError):
                coordinator.qbit_login()

    def test_qbit_login_rejects_explicit_auth_failure(self):
        with patch.object(
            coordinator,
            "request_bytes",
            return_value=(403, b"Forbidden"),
        ):
            with self.assertRaises(coordinator.QBitAuthError):
                coordinator.qbit_login()

    def test_extract_security_state_from_json_object(self):
        self.assertEqual(
            coordinator.extract_security_state(b'{"state":"SAFE"}'),
            "SAFE",
        )

    def test_extract_security_state_from_plain_text(self):
        self.assertEqual(coordinator.extract_security_state(b"safe\n"), "SAFE")

    def test_qbit_path_to_security_relative_for_tv(self):
        self.assertEqual(
            coordinator.qbit_path_to_security_relative(
                PurePosixPath("/data/downloads/tv/Show/file.mkv")
            ),
            "tv/Show/file.mkv",
        )

    def test_qbit_path_to_security_relative_for_movies(self):
        self.assertEqual(
            coordinator.qbit_path_to_security_relative(
                PurePosixPath("/data/downloads/movies/Movie/file.mkv")
            ),
            "movies/Movie/file.mkv",
        )

    def test_sonarr_payload_uses_downloaded_episodes_scan(self):
        payload = coordinator.build_import_payload(
            SONARR,
            {
                "hash": "abc123def",
                "content_path": "/data/downloads/tv/Show.S01E01",
            },
        )
        self.assertEqual(payload["name"], "DownloadedEpisodesScan")
        self.assertEqual(payload["downloadClientId"], "ABC123DEF")
        self.assertEqual(payload["importMode"], "copy")

    def test_radarr_payload_uses_downloaded_movies_scan(self):
        payload = coordinator.build_import_payload(
            RADARR,
            {
                "hash": "abc123def",
                "content_path": "/data/downloads/movies/Movie.2026",
            },
        )
        self.assertEqual(payload["name"], "DownloadedMoviesScan")
        self.assertEqual(payload["downloadClientId"], "ABC123DEF")
        self.assertEqual(payload["importMode"], "copy")

    def test_build_import_payload_rejects_wrong_target_root(self):
        with self.assertRaises(RuntimeError):
            coordinator.build_import_payload(
                RADARR,
                {
                    "hash": "abc123",
                    "content_path": "/data/downloads/tv/Show.S01E01",
                },
            )

    def test_command_outcome(self):
        self.assertEqual(
            coordinator.command_outcome(
                {"status": "completed", "result": "successful"}
            ),
            "success",
        )
        self.assertEqual(
            coordinator.command_outcome(
                {"status": "completed", "result": "unsuccessful"}
            ),
            "failure",
        )
        self.assertEqual(
            coordinator.command_outcome({"status": "started", "result": "unknown"}),
            "pending",
        )

    def test_target_scoped_state_round_trip(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            old_state_file = coordinator.STATE_FILE
            coordinator.STATE_FILE = Path(temp_dir) / "state.json"
            try:
                state = {}
                torrent = {"hash": "abc123", "name": "Example"}
                coordinator.set_state(
                    state,
                    RADARR,
                    torrent,
                    "import_requested",
                    arrCommandId=42,
                )
                loaded = coordinator.load_state()
                self.assertEqual(
                    loaded["radarr:abc123"]["status"],
                    "import_requested",
                )
                self.assertEqual(loaded["radarr:abc123"]["arrCommandId"], 42)
            finally:
                coordinator.STATE_FILE = old_state_file

    def test_sonarr_legacy_state_is_read(self):
        legacy = {"abc123": {"status": "waiting"}}
        self.assertEqual(
            coordinator.previous_state(legacy, SONARR, "abc123"),
            {"status": "waiting"},
        )


if __name__ == "__main__":
    unittest.main()
