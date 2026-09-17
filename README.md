# Security-gated Sonarr + Radarr torrent stack

This Docker Compose project deploys and configures:

- Sonarr for TV
- Radarr for movies
- Prowlarr for indexers
- qBittorrent for downloading
- FileSecurityManager for completed-download security checks
- a small Python coordinator that only allows Sonarr/Radarr imports after every selected torrent file is reported `SAFE`

The coordinator is workflow glue only: qBittorrent remains authoritative for torrent state, FileSecurityManager for security state, and Sonarr/Radarr for media import.

## Data flow

```text
Prowlarr
  ├─> Sonarr ─┐
  └─> Radarr ─┤
              v
     Gluetun / PIA VPN
              |
              v
         qBittorrent
          ├─ sonarr -> /data/downloads/tv
          └─ radarr -> /data/downloads/movies
                    |
                    v
           FileSecurityManager
                    |
                    v
               coordinator
             ├─> Sonarr -> /data/media/tv
             └─> Radarr -> /data/media/movies
```

Incomplete downloads use `/data/downloads/incomplete` and are not exposed to FileSecurityManager.

## Important fixes in this build

This build incorporates the bootstrap issues found during live testing:

- all credentials are service-specific (`QBITTORRENT_USERNAME`, etc.); generic `USERNAME`/`PASSWORD` are gone
- qBittorrent successful login is no longer identified by a specific response body or cookie name
- both qBittorrent `200` and `204` login responses are followed by an authenticated `/api/v2/app/preferences` request; that follow-up is the proof of success
- coordinator authentication failures use a long retry delay so a bad password cannot rapidly trigger qBittorrent's IP-ban protection
- fresh-start waits are bounded and print container state/logs instead of hanging forever
- Sonarr, Radarr, Prowlarr, qBittorrent and FileSecurityManager are all checked for real readiness before configuration begins
- qBittorrent is configured before the *arr download-client links are created
- qBittorrent Automatic Torrent Management and category paths are applied and read back for verification
- the coordinator is in the `runtime` Compose profile, so a plain `docker compose up` cannot start imports before configuration is complete
- `run.sh` explicitly starts the coordinator last, after a final cross-service verification
- setup is idempotent: re-running `./run.sh` updates/verifies the existing configuration instead of requiring a fresh clone

## PIA VPN / Gluetun

qBittorrent is now forced through a Gluetun sidecar network namespace. It has no independent Docker network and publishes no ports itself. The qBittorrent WebUI is exposed through Gluetun on host port `8080`; Sonarr, Radarr and the coordinator reach it internally at `gluetun:8080`. If the VPN tunnel drops, Gluetun's firewall acts as a kill switch for qBittorrent traffic.

PIA is configured with Gluetun's native OpenVPN integration and optional native VPN port forwarding. When PIA supplies a forwarded port, Gluetun automatically updates qBittorrent's listening port. The project defaults to `PORT_FORWARD_ONLY=true` and `VPN_PORT_FORWARDING=on`; set `PIA_VPN_PORT_FORWARDING=off` if you do not want VPN-side port forwarding.

A ready `.env` is included with generated local Sonarr/Radarr/Prowlarr/qBittorrent passwords. The only values intentionally left as placeholders are your PIA subscription credentials. Fill in:

```env
PIA_OPENVPN_USER=...
PIA_OPENVPN_PASSWORD=...
```

If you prefer to regenerate the file yourself, `.env.example` remains included as the template.

`PIA_SERVER_REGIONS` is optional. Leave it blank to let Gluetun choose a compatible PIA server, or set a comma-separated PIA region filter.

To verify the effective public IP after startup:

```bash
docker compose exec gluetun wget -qO- https://ipinfo.io/ip
```

The returned address should be the VPN exit address, not your normal WAN address. You can also inspect the tunnel and port-forwarding logs with:

```bash
docker compose logs --tail=100 gluetun
```

## qBittorrent routing

The configuration script sets and verifies:

```text
Default save path:               /data/downloads
Incomplete path:                 /data/downloads/incomplete
Default Torrent Management Mode: Automatic
Sonarr category:                 sonarr -> /data/downloads/tv
Radarr category:                 radarr -> /data/downloads/movies
```

It also enables:

```text
auto_tmm_enabled=true
torrent_changed_tmm_enabled=true
save_path_changed_tmm_enabled=true
category_changed_tmm_enabled=true
use_category_paths_in_manual_mode=true
```

Existing torrents already assigned to the `sonarr` or `radarr` category are switched to Automatic Torrent Management when the qBittorrent configuration script is rerun.

## Security gate

Normal Completed Download Handling is disabled in Sonarr and Radarr. The coordinator then:

1. polls qBittorrent for completed torrents in the `sonarr` and `radarr` categories
2. reads the selected files for each torrent
3. asks FileSecurityManager for each file's state using `/api/v1/files/state?path=...`
4. waits until every selected file is in `FILE_SECURITY_SAFE_STATES` (`SAFE` by default)
5. sends `DownloadedEpisodesScan` to Sonarr or `DownloadedMoviesScan` to Radarr
6. follows the returned command until it succeeds or fails
7. persists state in `runtime/coordinator/state.json` and adds a terminal qBittorrent tag

Anything not explicitly safe remains blocked from import.

## Fresh installation

Create the environment file:

```bash
cp .env.example .env
nano .env
```

The example passwords deliberately use unmistakable values such as:

```env
QBITTORRENT_PASSWORD=CHANGE_THIS_QBITTORRENT_PASSWORD
```

`run.sh` refuses to start while a `CHANGE_THIS_*` password remains. A value such as `replace-me` is not treated specially; if you deliberately choose it, it is passed through normally.

Check your host IDs and put the matching values in `.env`:

```bash
id
```

Then run:

```bash
chmod 600 .env
./scripts/test-project.sh
./run.sh
```

`./run.sh` is the intended deployment entry point. You do **not** need to run `docker compose up` first.

The startup order is:

```text
create directories
-> validate Compose
-> stop any old coordinator
-> start base services
-> wait for all base services to be genuinely ready
-> configure qBittorrent
-> configure Sonarr
-> configure Radarr
-> configure Prowlarr
-> create/verify cross-service links and indexers
-> run final verification
-> build/start coordinator LAST
```

Every bootstrap wait has a timeout. If a service exits or a timeout is reached, the setup prints its recent logs and exits non-zero instead of hanging indefinitely.

## Coordinator profile

The coordinator has:

```yaml
profiles: ["runtime"]
```

Therefore this command on a fresh checkout:

```bash
docker compose up -d
```

starts the base services but not the coordinator. That prevents the coordinator from attempting qBittorrent authentication before first-run credentials have been configured.

`run.sh` starts it explicitly at the end:

```bash
docker compose --profile runtime up -d --build --force-recreate coordinator
```

## Useful `.env` settings

```env
QBITTORRENT_SONARR_CATEGORY=sonarr
QBITTORRENT_SONARR_CATEGORY_PATH=/data/downloads/tv
QBITTORRENT_RADARR_CATEGORY=radarr
QBITTORRENT_RADARR_CATEGORY_PATH=/data/downloads/movies

STACK_STARTUP_TIMEOUT_SECONDS=180
STACK_SERVICE_WAIT_SECONDS=120
QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS=60
QBITTORRENT_AUTH_RETRY_SECONDS=300

SONARR_IMPORT_MODE=copy
RADARR_IMPORT_MODE=copy
COORDINATOR_DRY_RUN=false
```

## Web interfaces

Replace `<server-ip>` with the Docker host address.

| Service | Address |
| --- | --- |
| Sonarr | `http://<server-ip>:8989` |
| Radarr | `http://<server-ip>:7878` |
| qBittorrent | `http://<server-ip>:8080` |
| Prowlarr | `http://<server-ip>:9696` |
| FileSecurityManager API | `http://127.0.0.1:8081` |

FileSecurityManager is intentionally host-bound to localhost. Containers use `http://file-security:8080` internally.

## Verify routing and imports

After a successful `./run.sh`, qBittorrent should show:

```text
sonarr -> /data/downloads/tv
radarr -> /data/downloads/movies
```

A Sonarr download should flow through:

```text
/data/downloads/incomplete
        ->
/data/downloads/tv
        -> SAFE ->
/data/media/tv
```

A Radarr download should flow through:

```text
/data/downloads/incomplete
        ->
/data/downloads/movies
        -> SAFE ->
/data/media/movies
```

Useful checks:

```bash
docker compose --profile runtime ps
docker compose --profile runtime logs -f coordinator file-security sonarr radarr qbittorrent
find data/downloads -type f -maxdepth 5
find data/media -type f -maxdepth 5
```

A successful coordinator import looks like:

```text
All dependencies are ready
... all selected torrent files are SAFE
... DownloadedEpisodesScan accepted
... Sonarr import completed successfully
```

or the equivalent Radarr messages.

## Dry run

With:

```env
COORDINATOR_DRY_RUN=true
```

the coordinator performs qBittorrent/FileSecurityManager checks but does not send the final import command. For normal imports use:

```env
COORDINATOR_DRY_RUN=false
```

After changing only coordinator environment values:

```bash
docker compose --profile runtime up -d --build --force-recreate coordinator
```

## Re-running setup

The configuration is designed to be idempotent. To reapply and verify everything after editing `.env`:

```bash
./run.sh
```

There is no need to delete `config/`, `data/`, or named volumes for an ordinary configuration update.

## Fully destructive reset

Only use this if you intentionally want fresh application databases, settings, downloads and media:

```bash
docker compose --profile runtime down -v --remove-orphans
sudo rm -rf config data runtime
```

Then recreate `.env` and run `./run.sh` again. This is destructive.

## Project checks

```bash
./scripts/test-project.sh
```

The test script checks shell syntax, bootstrap regression guards, namespaced credentials, qBittorrent routing configuration, Python syntax/unit tests, and Compose configuration when Docker is available.
