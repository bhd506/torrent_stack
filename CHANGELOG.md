# Changelog

## 2026-09-17 - bootstrap reliability / authentication patch

- Replaced timing-driven first-run setup with bounded readiness checks for Sonarr, Radarr, Prowlarr, qBittorrent and FileSecurityManager.
- Added `scripts/wait-for-services.sh` and shared diagnostics helpers.
- Removed the infinite Sonarr/Radarr `config.xml` wait loops.
- Timeouts now print container state and recent logs instead of hanging indefinitely.
- Changed configuration order so qBittorrent is bootstrapped before *arr download-client linking.
- Fixed qBittorrent authentication to verify the authenticated session using `/api/v2/app/preferences` rather than relying on `Ok.`, `204`, `SID`, or `QBT_SID_*` details.
- Fixed the same cookie-name assumption in the Python coordinator.
- Added a 300-second default coordinator backoff after explicit qBittorrent authentication rejection to avoid rapid IP bans.
- Reduced permanent-credential bootstrap retries so setup fails clearly instead of hammering qBittorrent.
- Added explicit detection/diagnostics for qBittorrent IP-ban responses during setup.
- Added a final cross-service verification pass before the coordinator starts.
- Added `profiles: ["runtime"]` to the coordinator so plain `docker compose up` cannot start it before bootstrap configuration.
- `run.sh` now stops an existing coordinator during reconfiguration and starts it last after verification.
- Changed `.env.example` passwords from ambiguous `replace-me` values to `CHANGE_THIS_*` placeholders; `replace-me` itself remains valid if deliberately chosen.
- Added bootstrap regression checks alongside the Python coordinator tests.

## 2026-09-17 - qBittorrent first-run authentication race fix

- Fresh installs wait for LinuxServer qBittorrent to emit the temporary first-run password instead of reading the log only once.
- Repeated stale temporary passwords are not retried continuously.
- Added `QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS`.

## 2026-09-17 - Sonarr + Radarr amended build

- Added Radarr as a first-class service with `/data/downloads/movies` and `/data/media/movies`.
- Added Prowlarr -> Radarr and Radarr -> qBittorrent configuration.
- Extended the security coordinator to gate both Sonarr and Radarr imports.
- Replaced generic `USERNAME` / `PASSWORD` variables with service-specific names.
- Enabled and verified qBittorrent Automatic Torrent Management and category relocation behavior.
- Existing Sonarr/Radarr-category torrents are switched to Automatic Torrent Management when setup is rerun.
