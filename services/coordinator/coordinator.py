#!/usr/bin/env python3
"""Security gate between qBittorrent completion and Sonarr/Radarr import.

The coordinator does not scan files itself. qBittorrent is authoritative for
which torrent files are complete, FileSecurityManager is authoritative for each
file's security state, and Sonarr/Radarr are authoritative for media import.
"""

from __future__ import annotations

import http.cookiejar
import json
import logging
import os
import posixpath
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any


LOG = logging.getLogger("torrent-security-coordinator")


def env(name: str, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if value is None or value == "":
        raise RuntimeError(f"Required environment variable is missing: {name}")
    return value


def env_int(name: str, default: int) -> int:
    value = int(os.getenv(name, str(default)))
    if value < 1:
        raise RuntimeError(f"{name} must be a positive integer")
    return value


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name, "true" if default else "false").strip().lower()
    if value in {"1", "true", "yes", "on"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    raise RuntimeError(f"{name} must be true or false")


def env_states(name: str, default: str = "") -> set[str]:
    return {
        part.strip().upper()
        for part in os.getenv(name, default).split(",")
        if part.strip()
    }


def import_mode(name: str, default: str = "copy") -> str:
    value = env(name, default).lower()
    if value not in {"copy", "move", "auto"}:
        raise RuntimeError(f"{name} must be copy, move, or auto")
    return value


@dataclass(frozen=True)
class ArrTarget:
    key: str
    label: str
    category: str
    category_root: PurePosixPath
    url: str
    config_file: Path
    import_mode: str
    command_name: str


QBITTORRENT_URL = env("QBITTORRENT_URL", "http://gluetun:8080").rstrip("/")
QBITTORRENT_USERNAME = env("QBITTORRENT_USERNAME")
QBITTORRENT_PASSWORD = env("QBITTORRENT_PASSWORD")
QBITTORRENT_COMPLETED_ROOT = PurePosixPath(
    env("QBITTORRENT_COMPLETED_ROOT", "/data/downloads")
)

FILE_SECURITY_URL = env("FILE_SECURITY_URL", "http://file-security:8080").rstrip("/")
FILE_SECURITY_SAFE_STATES = env_states("FILE_SECURITY_SAFE_STATES", "SAFE")
FILE_SECURITY_BLOCK_STATES = env_states("FILE_SECURITY_BLOCK_STATES")

TARGETS = (
    ArrTarget(
        key="sonarr",
        label="Sonarr",
        category=env("QBITTORRENT_SONARR_CATEGORY", "sonarr"),
        category_root=PurePosixPath(
            env("QBITTORRENT_SONARR_CATEGORY_PATH", "/data/downloads/tv")
        ),
        url=env("SONARR_URL", "http://sonarr:8989").rstrip("/"),
        config_file=Path(env("SONARR_CONFIG_FILE", "/sonarr-config/config.xml")),
        import_mode=import_mode("SONARR_IMPORT_MODE"),
        command_name="DownloadedEpisodesScan",
    ),
    ArrTarget(
        key="radarr",
        label="Radarr",
        category=env("QBITTORRENT_RADARR_CATEGORY", "radarr"),
        category_root=PurePosixPath(
            env("QBITTORRENT_RADARR_CATEGORY_PATH", "/data/downloads/movies")
        ),
        url=env("RADARR_URL", "http://radarr:7878").rstrip("/"),
        config_file=Path(env("RADARR_CONFIG_FILE", "/radarr-config/config.xml")),
        import_mode=import_mode("RADARR_IMPORT_MODE"),
        command_name="DownloadedMoviesScan",
    ),
)

DOWNLOADS_MOUNT = Path(env("DOWNLOADS_MOUNT", "/downloads"))
STATE_FILE = Path(env("COORDINATOR_STATE_FILE", "/state/state.json"))
POLL_INTERVAL_SECONDS = env_int("COORDINATOR_POLL_INTERVAL_SECONDS", 10)
HTTP_TIMEOUT_SECONDS = env_int("COORDINATOR_HTTP_TIMEOUT_SECONDS", 20)
QBITTORRENT_AUTH_RETRY_SECONDS = env_int("QBITTORRENT_AUTH_RETRY_SECONDS", 300)
DRY_RUN = env_bool("COORDINATOR_DRY_RUN", False)

TERMINAL_STATE_STATUSES = {"imported", "import_failed", "security_blocked"}
TERMINAL_TAGS = {"security-imported", "security-import-failed", "security-blocked"}


class HttpError(RuntimeError):
    pass


class QBitAuthError(HttpError):
    """qBittorrent explicitly rejected or failed to establish authentication."""

    pass


def is_under(path: PurePosixPath, root: PurePosixPath) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def validate_configuration() -> None:
    categories = [target.category for target in TARGETS]
    if len(categories) != len(set(categories)):
        raise RuntimeError("Sonarr and Radarr must use different qBittorrent categories")

    for target in TARGETS:
        if not target.category_root.is_absolute():
            raise RuntimeError(f"{target.label} category path must be absolute")
        if not is_under(target.category_root, QBITTORRENT_COMPLETED_ROOT):
            raise RuntimeError(
                f"{target.label} category path must be inside {QBITTORRENT_COMPLETED_ROOT}"
            )


def request_bytes(
    opener: urllib.request.OpenerDirector,
    url: str,
    *,
    method: str = "GET",
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
    acceptable_statuses: set[int] | None = None,
) -> tuple[int, bytes]:
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})

    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()
        if acceptable_statuses and exc.code in acceptable_statuses:
            return exc.code, body
        raise HttpError(
            f"HTTP {exc.code} for {url}: {body.decode(errors='replace')}"
        ) from exc
    except urllib.error.URLError as exc:
        raise HttpError(f"Unable to reach {url}: {exc.reason}") from exc


def request_json(
    opener: urllib.request.OpenerDirector,
    url: str,
    *,
    method: str = "GET",
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
    acceptable_statuses: set[int] | None = None,
) -> tuple[int, Any | None]:
    status, body = request_bytes(
        opener,
        url,
        method=method,
        data=data,
        headers=headers,
        acceptable_statuses=acceptable_statuses,
    )
    if status == 404 and acceptable_statuses and 404 in acceptable_statuses:
        return status, None
    try:
        return status, json.loads(body.decode())
    except json.JSONDecodeError as exc:
        raise HttpError(
            f"Expected JSON from {url}, got: {body.decode(errors='replace')}"
        ) from exc


DEFAULT_OPENER = urllib.request.build_opener()
QBIT_COOKIE_JAR = http.cookiejar.CookieJar()
QBIT_OPENER = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(QBIT_COOKIE_JAR)
)


def qbit_headers() -> dict[str, str]:
    return {"Referer": f"{QBITTORRENT_URL}/"}


def qbit_login() -> None:
    """Authenticate and prove the resulting qBittorrent session works.

    qBittorrent versions differ in successful login response details (for
    example 200/"Ok." vs 204/empty) and in session-cookie names. The cookie jar
    already preserves whatever Set-Cookie qBittorrent supplies, so the reliable
    contract is an authenticated follow-up request, not response text or a
    hard-coded cookie name.
    """

    QBIT_COOKIE_JAR.clear()
    payload = urllib.parse.urlencode(
        {"username": QBITTORRENT_USERNAME, "password": QBITTORRENT_PASSWORD}
    ).encode()

    status, body = request_bytes(
        QBIT_OPENER,
        f"{QBITTORRENT_URL}/api/v2/auth/login",
        method="POST",
        data=payload,
        headers={
            **qbit_headers(),
            "Content-Type": "application/x-www-form-urlencoded",
        },
        acceptable_statuses={401, 403},
    )

    if status in {401, 403}:
        message = body.decode(errors="replace").strip()
        raise QBitAuthError(
            f"qBittorrent rejected credentials (HTTP {status}: {message or 'empty response'})"
        )
    if status not in {200, 204}:
        raise HttpError(
            f"Unexpected qBittorrent login response HTTP {status}: "
            f"{body.decode(errors='replace').strip()!r}"
        )

    verify_status, verify_body = request_bytes(
        QBIT_OPENER,
        f"{QBITTORRENT_URL}/api/v2/app/preferences",
        headers=qbit_headers(),
        acceptable_statuses={401, 403},
    )
    if verify_status in {401, 403}:
        message = verify_body.decode(errors="replace").strip()
        raise QBitAuthError(
            "qBittorrent login response was accepted, but the session was not "
            f"authenticated (HTTP {verify_status}: {message or 'empty response'})"
        )
    if verify_status != 200:
        raise HttpError(
            f"qBittorrent session verification returned HTTP {verify_status}"
        )

    try:
        preferences = json.loads(verify_body.decode())
    except json.JSONDecodeError as exc:
        raise HttpError("qBittorrent session verification did not return JSON") from exc
    if not isinstance(preferences, dict):
        raise HttpError("qBittorrent session verification returned an unexpected payload")


def qbit_get_json(path: str, params: dict[str, str] | None = None) -> Any:
    query = f"?{urllib.parse.urlencode(params)}" if params else ""
    _status, payload = request_json(
        QBIT_OPENER,
        f"{QBITTORRENT_URL}{path}{query}",
        headers=qbit_headers(),
    )
    return payload


def qbit_add_tag(torrent_hash: str, tag: str) -> None:
    payload = urllib.parse.urlencode({"hashes": torrent_hash, "tags": tag}).encode()
    request_bytes(
        QBIT_OPENER,
        f"{QBITTORRENT_URL}/api/v2/torrents/addTags",
        method="POST",
        data=payload,
        headers={
            **qbit_headers(),
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )


def read_arr_api_key(target: ArrTarget) -> str:
    tree = ET.parse(target.config_file)
    api_key = tree.getroot().findtext("ApiKey")
    if not api_key:
        raise RuntimeError(f"ApiKey was not found in {target.config_file}")
    return api_key.strip()


def arr_headers(api_key: str, json_body: bool = False) -> dict[str, str]:
    headers = {"X-Api-Key": api_key}
    if json_body:
        headers["Content-Type"] = "application/json"
    return headers


def arr_get_json(
    target: ArrTarget,
    api_key: str,
    path: str,
    *,
    acceptable_statuses: set[int] | None = None,
) -> tuple[int, Any | None]:
    return request_json(
        DEFAULT_OPENER,
        f"{target.url}{path}",
        headers=arr_headers(api_key),
        acceptable_statuses=acceptable_statuses,
    )


def arr_post_json(target: ArrTarget, api_key: str, path: str, payload: Any) -> Any:
    _status, body = request_json(
        DEFAULT_OPENER,
        f"{target.url}{path}",
        method="POST",
        data=json.dumps(payload).encode(),
        headers=arr_headers(api_key, json_body=True),
    )
    return body


def extract_security_state(body: bytes) -> str:
    """Accept plain text, JSON strings, or common JSON object shapes."""
    text = body.decode(errors="replace").strip()
    if not text:
        return "UNKNOWN"

    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return text.strip('"').upper()

    if isinstance(payload, str):
        return payload.upper()

    if isinstance(payload, dict):
        for key in ("state", "status", "fileState", "file_state"):
            value = payload.get(key)
            if isinstance(value, str):
                return value.upper()

    return "UNKNOWN"


def file_security_state(relative_path: str) -> str:
    query = urllib.parse.urlencode({"path": relative_path})
    status, body = request_bytes(
        DEFAULT_OPENER,
        f"{FILE_SECURITY_URL}/api/v1/files/state?{query}",
        acceptable_statuses={404},
    )
    if status == 404:
        return "UNKNOWN"
    return extract_security_state(body)


def qbit_path_to_security_relative(path: PurePosixPath) -> str:
    return path.relative_to(QBITTORRENT_COMPLETED_ROOT).as_posix()


def local_path_for_qbit(path: PurePosixPath) -> Path:
    return DOWNLOADS_MOUNT / qbit_path_to_security_relative(path)


def resolve_torrent_file_path(
    target: ArrTarget, torrent: dict[str, Any], file_name: str
) -> PurePosixPath:
    """Resolve a qBittorrent file-list name to an absolute shared /data path."""
    name = PurePosixPath(file_name)
    save_path = PurePosixPath(str(torrent.get("save_path") or ""))
    content_path = PurePosixPath(str(torrent.get("content_path") or ""))

    candidates: list[PurePosixPath] = []
    if save_path.is_absolute():
        candidates.append(save_path / name)
    if content_path.is_absolute():
        candidates.append(content_path.parent / name)
        candidates.append(content_path / name)
        if name.name == content_path.name:
            candidates.append(content_path)

    unique: list[PurePosixPath] = []
    for candidate in candidates:
        normalized = PurePosixPath(posixpath.normpath(str(candidate)))
        if normalized not in unique and is_under(normalized, target.category_root):
            unique.append(normalized)

    for candidate in unique:
        if local_path_for_qbit(candidate).exists():
            return candidate

    if unique:
        # A security action may already have removed/quarantined the file. The
        # original path is still useful for asking FileSecurityManager about
        # its recorded state.
        return unique[0]

    raise RuntimeError(
        f"Torrent file path is outside {target.label} completed-download root: {file_name}"
    )


def selected_torrent_files(torrent: dict[str, Any]) -> list[dict[str, Any]]:
    files = qbit_get_json("/api/v2/torrents/files", {"hash": torrent["hash"]})
    if not isinstance(files, list):
        raise RuntimeError("qBittorrent file list was not a list")
    return [
        item
        for item in files
        if int(item.get("priority", 1)) != 0
        and float(item.get("progress", 0.0)) >= 1.0
    ]


def security_verdict(
    target: ArrTarget, torrent: dict[str, Any]
) -> tuple[str, list[tuple[str, str]]]:
    files = selected_torrent_files(torrent)
    if not files:
        return "waiting", []

    states: list[tuple[str, str]] = []
    for item in files:
        full_path = resolve_torrent_file_path(target, torrent, str(item["name"]))
        relative = qbit_path_to_security_relative(full_path)
        state = file_security_state(relative)
        states.append((relative, state))

    if FILE_SECURITY_BLOCK_STATES and any(
        state in FILE_SECURITY_BLOCK_STATES for _path, state in states
    ):
        return "blocked", states

    if all(state in FILE_SECURITY_SAFE_STATES for _path, state in states):
        return "safe", states

    return "waiting", states


def build_import_payload(target: ArrTarget, torrent: dict[str, Any]) -> dict[str, Any]:
    content_path = PurePosixPath(str(torrent.get("content_path") or ""))
    if not content_path.is_absolute() or not is_under(content_path, target.category_root):
        raise RuntimeError(
            f"qBittorrent content path is outside {target.label} completed-download root: "
            f"{content_path}"
        )

    return {
        "name": target.command_name,
        "path": str(content_path),
        # *arr normalises qBittorrent download IDs as upper-case infohashes.
        "downloadClientId": str(torrent["hash"]).upper(),
        "importMode": target.import_mode,
    }


def request_arr_import(
    target: ArrTarget, api_key: str, torrent: dict[str, Any]
) -> dict[str, Any]:
    payload = build_import_payload(target, torrent)

    if DRY_RUN:
        LOG.info(
            "DRY RUN: would ask %s to scan/import %s",
            target.label,
            payload["path"],
        )
        return {"id": "dry-run", "status": "dry-run", "result": "unknown"}

    command = arr_post_json(target, api_key, "/api/v3/command", payload)
    if not isinstance(command, dict) or command.get("id") is None:
        raise RuntimeError(f"{target.label} did not return a command id")

    LOG.info(
        "%s: %s %s accepted (command id=%s)",
        torrent.get("name") or torrent["hash"],
        target.label,
        target.command_name,
        command["id"],
    )
    return command


def command_outcome(command: dict[str, Any]) -> str:
    status = str(command.get("status") or "").lower()
    result = str(command.get("result") or "").lower()

    if status == "completed":
        return "success" if result == "successful" else "failure"
    if status in {"failed", "aborted"}:
        return "failure"
    return "pending"


def arr_command(
    target: ArrTarget, api_key: str, command_id: Any
) -> dict[str, Any] | None:
    status, payload = arr_get_json(
        target,
        api_key,
        f"/api/v3/command/{urllib.parse.quote(str(command_id), safe='')}",
        acceptable_statuses={404},
    )
    if status == 404:
        return None
    return payload if isinstance(payload, dict) else None


def load_state() -> dict[str, Any]:
    try:
        with STATE_FILE.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
            return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError) as exc:
        LOG.warning("Unable to read coordinator state; starting empty: %s", exc)
        return {}


def save_state(state: dict[str, Any]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temp = STATE_FILE.with_suffix(".tmp")
    with temp.open("w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temp.replace(STATE_FILE)


def state_key(target: ArrTarget, torrent_hash: str) -> str:
    return f"{target.key}:{torrent_hash.lower()}"


def previous_state(
    state: dict[str, Any], target: ArrTarget, torrent_hash: str
) -> dict[str, Any]:
    current = state.get(state_key(target, torrent_hash))
    if isinstance(current, dict):
        return current

    # Backward compatibility with the Sonarr-only coordinator's hash keys.
    if target.key == "sonarr":
        legacy = state.get(torrent_hash)
        if isinstance(legacy, dict):
            return legacy
    return {}


def set_state(
    state: dict[str, Any],
    target: ArrTarget,
    torrent: dict[str, Any],
    status: str,
    **extra: Any,
) -> None:
    state[state_key(target, torrent["hash"])] = {
        "target": target.key,
        "name": torrent.get("name"),
        "status": status,
        "updatedAt": int(time.time()),
        **extra,
    }
    save_state(state)


def torrent_tags(torrent: dict[str, Any]) -> set[str]:
    raw = str(torrent.get("tags") or "")
    return {tag.strip() for tag in raw.split(",") if tag.strip()}


def safe_add_tag(torrent_hash: str, tag: str) -> None:
    try:
        qbit_add_tag(torrent_hash, tag)
    except HttpError as exc:
        LOG.warning("Could not tag qBittorrent torrent %s: %s", torrent_hash, exc)


def update_requested_import(
    target: ArrTarget,
    api_key: str,
    state: dict[str, Any],
    torrent: dict[str, Any],
    previous: dict[str, Any],
) -> bool:
    """Return True while/after a previously submitted *arr command is handled."""
    if previous.get("status") != "import_requested":
        return False

    command_id = (
        previous.get("arrCommandId")
        or previous.get("sonarrCommandId")
        or previous.get("radarrCommandId")
    )
    if not command_id:
        set_state(
            state,
            target,
            torrent,
            "import_failed",
            reason=f"missing {target.label} command id",
        )
        safe_add_tag(torrent["hash"], "security-import-failed")
        return True

    try:
        command = arr_command(target, api_key, command_id)
    except HttpError as exc:
        LOG.warning(
            "%s: cannot read %s command %s: %s",
            torrent["name"],
            target.label,
            command_id,
            exc,
        )
        return True

    if command is None:
        LOG.warning(
            "%s: %s command %s is no longer available; leaving import blocked",
            torrent["name"],
            target.label,
            command_id,
        )
        return True

    outcome = command_outcome(command)
    if outcome == "pending":
        return True

    if outcome == "success":
        LOG.info("%s: %s import completed successfully", torrent["name"], target.label)
        safe_add_tag(torrent["hash"], "security-imported")
        set_state(
            state,
            target,
            torrent,
            "imported",
            arrCommandId=command_id,
        )
        return True

    reason = command.get("exception") or command.get("message") or command.get("result")
    LOG.error("%s: %s import failed: %s", torrent["name"], target.label, reason)
    safe_add_tag(torrent["hash"], "security-import-failed")
    set_state(
        state,
        target,
        torrent,
        "import_failed",
        arrCommandId=command_id,
        reason=reason,
    )
    return True


def wait_for_dependencies() -> dict[str, str]:
    labels = ", ".join(target.label for target in TARGETS)
    LOG.info(
        "Waiting for %s, qBittorrent, and FileSecurityManager dependencies...",
        labels,
    )
    while True:
        try:
            api_keys: dict[str, str] = {}
            for target in TARGETS:
                if not target.config_file.is_file():
                    raise RuntimeError(f"{target.label} config.xml does not exist yet")
                api_key = read_arr_api_key(target)
                arr_get_json(target, api_key, "/api/v3/system/status")
                api_keys[target.key] = api_key

            qbit_login()
            request_bytes(DEFAULT_OPENER, f"{FILE_SECURITY_URL}/api/v1/health")

            LOG.info("All dependencies are ready")
            return api_keys
        except QBitAuthError as exc:
            LOG.error(
                "qBittorrent authentication is not valid: %s; retrying in %ss to avoid triggering an IP ban",
                exc,
                QBITTORRENT_AUTH_RETRY_SECONDS,
            )
            time.sleep(QBITTORRENT_AUTH_RETRY_SECONDS)
        except (RuntimeError, HttpError, ET.ParseError, OSError) as exc:
            LOG.info("Still waiting: %s", exc)
            time.sleep(5)


def process_target(
    target: ArrTarget, api_key: str, state: dict[str, Any]
) -> None:
    torrents = qbit_get_json(
        "/api/v2/torrents/info",
        {"filter": "completed", "category": target.category},
    )
    if not isinstance(torrents, list):
        raise RuntimeError("qBittorrent torrent list was not a list")

    for torrent in torrents:
        torrent_hash = str(torrent.get("hash") or "")
        if not torrent_hash:
            continue

        torrent["hash"] = torrent_hash
        torrent["name"] = str(torrent.get("name") or torrent_hash)

        tags = torrent_tags(torrent)
        if tags & TERMINAL_TAGS:
            continue

        previous = previous_state(state, target, torrent_hash)
        if previous.get("status") in TERMINAL_STATE_STATUSES:
            continue

        if update_requested_import(target, api_key, state, torrent, previous):
            continue

        try:
            verdict, states = security_verdict(target, torrent)
        except (HttpError, RuntimeError, ValueError, KeyError) as exc:
            LOG.warning(
                "%s [%s]: unable to obtain security verdict: %s",
                torrent["name"],
                target.label,
                exc,
            )
            continue

        state_summary = [f"{path}={file_state}" for path, file_state in states]

        if verdict == "blocked":
            blocked = [
                item
                for item in state_summary
                if item.rsplit("=", 1)[-1] in FILE_SECURITY_BLOCK_STATES
            ]
            LOG.error(
                "%s [%s]: FileSecurityManager reported a terminal blocked state; import disabled (%s)",
                torrent["name"],
                target.label,
                ", ".join(blocked),
            )
            safe_add_tag(torrent_hash, "security-blocked")
            set_state(
                state,
                target,
                torrent,
                "security_blocked",
                files=state_summary,
            )
            continue

        if verdict == "waiting":
            if previous.get("files") != state_summary or previous.get("status") != "waiting":
                LOG.info(
                    "%s [%s]: waiting for every selected file to become SAFE (%s)",
                    torrent["name"],
                    target.label,
                    ", ".join(state_summary) or "no completed files yet",
                )
                set_state(
                    state,
                    target,
                    torrent,
                    "waiting",
                    files=state_summary,
                )
            continue

        LOG.info(
            "%s [%s]: all selected torrent files are SAFE",
            torrent["name"],
            target.label,
        )

        try:
            command = request_arr_import(target, api_key, torrent)
        except (HttpError, RuntimeError, KeyError, TypeError) as exc:
            LOG.warning(
                "%s: %s import request failed: %s",
                torrent["name"],
                target.label,
                exc,
            )
            continue

        if DRY_RUN:
            # Kept non-terminal so switching dry-run off can process the same
            # torrent without manually clearing coordinator state.
            if previous.get("status") != "dry_run" or previous.get("files") != state_summary:
                set_state(
                    state,
                    target,
                    torrent,
                    "dry_run",
                    files=state_summary,
                )
            continue

        set_state(
            state,
            target,
            torrent,
            "import_requested",
            files=state_summary,
            arrCommandId=command["id"],
        )


def process_once(api_keys: dict[str, str], state: dict[str, Any]) -> None:
    for target in TARGETS:
        process_target(target, api_keys[target.key], state)


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    validate_configuration()
    for target in TARGETS:
        LOG.info(
            "Configured target: %s category=%s completedRoot=%s importMode=%s",
            target.label,
            target.category,
            target.category_root,
            target.import_mode,
        )
    LOG.info("Coordinator dryRun=%s", DRY_RUN)

    api_keys = wait_for_dependencies()
    state = load_state()

    while True:
        try:
            process_once(api_keys, state)
        except HttpError as exc:
            LOG.warning("API error: %s", exc)
            try:
                qbit_login()
            except HttpError:
                pass
        except Exception:
            LOG.exception("Unexpected coordinator error")

        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
