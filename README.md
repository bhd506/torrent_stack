# Automated Sonarr, Prowlarr and qBittorrent Stack

A Docker Compose stack that automatically deploys and configures:

- Sonarr for TV library management
- Prowlarr for indexer management
- qBittorrent for downloads

## Architecture

    Prowlarr
        |
        | synchronises indexers
        v
      Sonarr
        |
        | submits downloads
        v
    qBittorrent

The services communicate through Docker's internal network:

- `http://prowlarr:9696`
- `http://sonarr:8989`
- `http://qbittorrent:8080`

## Features

- Persistent bind-mounted configuration and data
- Automatic directory creation
- Automatic authentication configuration
- Automatic Sonarr root-folder configuration
- Automatic qBittorrent path and category configuration
- Sonarr-to-qBittorrent linking
- Prowlarr-to-Sonarr linking
- Automatic Prowlarr indexer configuration
- Rerunnable configuration scripts
- Single-command deployment

## Requirements

The host must have:

- Docker Engine
- Docker Compose plugin
- Bash
- curl
- jq
- sed

Check the main requirements:

    docker --version
    docker compose version
    bash --version
    curl --version
    jq --version

## Project layout

    .
    ├── compose.yaml
    ├── .env.example
    ├── .gitignore
    ├── run.sh
    ├── scripts/
    │   ├── configure.sh
    │   ├── configure-sonarr.sh
    │   ├── configure-qbittorrent.sh
    │   ├── configure-prowlarr.sh
    │   ├── configure-prowlarr-indexers.sh
    │   ├── link-sonarr-qbittorrent.sh
    │   └── link-prowlarr-sonarr.sh
    ├── config/
    │   ├── sonarr/
    │   ├── qbittorrent/
    │   └── prowlarr/
    └── data/
        ├── downloads/
        │   ├── incomplete/
        │   └── tv/
        └── media/
            └── tv/

The `config/` and `data/` directories are created automatically by `run.sh` and are excluded from Git.

## Data layout

`data/downloads/incomplete`

Contains downloads that are still in progress.

`data/downloads/tv`

Contains completed downloads submitted by Sonarr. qBittorrent can continue seeding from this location.

`data/media/tv`

Contains the final TV library organised by Sonarr.

Downloads and media share the same parent filesystem so Sonarr can use hard links when supported.

## Installation

Clone the repository:

    git clone <repository-url>
    cd <repository-directory>

Create the environment file:

    cp .env.example .env
    nano .env

Example `.env`:

    PUID=1000
    PGID=1000
    TZ=Europe/London

    USERNAME=admin
    PASSWORD=replace-with-a-strong-password

    QBITTORRENT_SAVE_PATH=/data/downloads
    QBITTORRENT_TEMP_PATH=/data/downloads/incomplete
    QBITTORRENT_CATEGORY=sonarr
    QBITTORRENT_CATEGORY_PATH=/data/downloads/tv
    QBITTORRENT_TORRENT_PORT=6881

Find your user and group IDs:

    id

Protect the environment file:

    chmod 600 .env

Deploy and configure the stack:

    ./run.sh

## What run.sh does

`run.sh` performs these operations:

1. Creates the required host directories
2. Validates the Compose configuration
3. Starts the Docker Compose services
4. Configures Sonarr
5. Configures qBittorrent
6. Configures Prowlarr
7. Links Sonarr to qBittorrent
8. Links Prowlarr to Sonarr
9. Configures the Prowlarr indexers

The scripts are intended to be rerunnable without creating duplicate integrations.

## Web interfaces

Replace `<server-ip>` with the Docker host's IP address or hostname.

| Service | Address |
| --- | --- |
| Sonarr | `http://<server-ip>:8989` |
| qBittorrent | `http://<server-ip>:8080` |
| Prowlarr | `http://<server-ip>:9696` |

All three services use the shared `USERNAME` and `PASSWORD` values from `.env`.

## Running configuration separately

Rerun all application configuration without managing Compose:

    ./scripts/configure.sh

Run an individual stage:

    ./scripts/configure-sonarr.sh
    ./scripts/configure-qbittorrent.sh
    ./scripts/configure-prowlarr.sh
    ./scripts/link-sonarr-qbittorrent.sh
    ./scripts/link-prowlarr-sonarr.sh
    ./scripts/configure-prowlarr-indexers.sh

## Common Docker commands

View status:

    docker compose ps

Follow logs:

    docker compose logs -f

View one service:

    docker compose logs --tail=100 sonarr
    docker compose logs --tail=100 qbittorrent
    docker compose logs --tail=100 prowlarr

Stop the stack:

    docker compose down

Start the stack without rerunning configuration:

    docker compose up -d

Recreate containers while retaining persistent state:

    docker compose up -d --force-recreate

## Resetting application state

Persistent application settings are stored under `config/`.

Reset Sonarr:

    docker compose stop sonarr
    sudo rm -rf config/sonarr
    ./run.sh

Reset qBittorrent:

    docker compose stop qbittorrent
    sudo rm -rf config/qbittorrent
    ./run.sh

Reset Prowlarr:

    docker compose stop prowlarr
    sudo rm -rf config/prowlarr
    ./run.sh

Back up a configuration directory instead of deleting it:

    mv config/sonarr "config/sonarr-backup-$(date +%Y%m%d-%H%M%S)"

Deleting `config/` resets application settings.

Deleting `data/` removes downloads and media.

## Using the Sonarr API

Sonarr can serve as the main backend API for a custom frontend.

Example request:

    curl \
      -H "X-Api-Key: YOUR_SONARR_API_KEY" \
      http://localhost:8989/api/v3/series

Keep the Sonarr API key in your backend. Do not embed it in browser JavaScript or a public frontend bundle.

A typical architecture is:

    Browser frontend
          |
          v
    Your backend API
          |
          v
      Sonarr API

## Security

Do not commit:

- `.env`
- `config/`
- `data/`
- `backups/`

These locations may contain passwords, API keys, databases, downloads and media.

Before committing:

    git status
    git diff --cached
    git ls-files .env config data backups

The final command should produce no output.

Do not expose the service ports directly to the public internet without suitable authentication, firewall rules, TLS and a trusted reverse proxy.

## Production notes

The configuration scripts run on the Docker host rather than inside a container. This avoids mounting the Docker socket into an initialization container.

The services use `restart: unless-stopped`, so Docker can restart them after a host reboot without rerunning `run.sh`.

Back up at least:

- `.env`
- `config/`

Back up `data/media/` according to the importance of the library.

## Legal use

Use this software and its configured indexers only for material that you are legally authorised to access, download and share.

## License

Add the chosen project license in a `LICENSE` file.
