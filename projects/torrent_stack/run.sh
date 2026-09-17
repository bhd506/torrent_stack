#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

if [[ ! -f .env ]]; then
    echo "Error: .env is missing. Copy .env.example to .env and edit it first." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

for command_name in docker curl jq sed; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

docker compose version >/dev/null 2>&1 || {
    echo "Error: Docker Compose plugin is not available." >&2
    exit 1
}

required_vars=(
    PUID PGID
    SONARR_USERNAME SONARR_PASSWORD
    RADARR_USERNAME RADARR_PASSWORD
    PROWLARR_USERNAME PROWLARR_PASSWORD
    QBITTORRENT_USERNAME QBITTORRENT_PASSWORD
    PIA_OPENVPN_USER PIA_OPENVPN_PASSWORD
)
for name in "${required_vars[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "Error: $name is missing from .env" >&2
        exit 1
    fi
done

# The example file uses unmistakable placeholders. `replace-me` remains a valid
# password if a user deliberately chooses it; only CHANGE_THIS_* is rejected.
for name in SONARR_PASSWORD RADARR_PASSWORD PROWLARR_PASSWORD QBITTORRENT_PASSWORD PIA_OPENVPN_USER PIA_OPENVPN_PASSWORD; do
    value="${!name}"
    if [[ "$value" == CHANGE_THIS_* ]]; then
        echo "Error: $name still contains the .env.example placeholder value." >&2
        echo "       Choose a real password before running the stack." >&2
        exit 1
    fi
done

SONARR_CATEGORY="${QBITTORRENT_SONARR_CATEGORY:-sonarr}"
SONARR_PATH="${QBITTORRENT_SONARR_CATEGORY_PATH:-/data/downloads/tv}"
RADARR_CATEGORY="${QBITTORRENT_RADARR_CATEGORY:-radarr}"
RADARR_PATH="${QBITTORRENT_RADARR_CATEGORY_PATH:-/data/downloads/movies}"

if [[ "$SONARR_PATH" != "/data/downloads/tv" ]]; then
    echo "Error: this integration expects QBITTORRENT_SONARR_CATEGORY_PATH=/data/downloads/tv" >&2
    echo "       because FileSecurityManager and the coordinator are mounted for that layout." >&2
    exit 1
fi

if [[ "$RADARR_PATH" != "/data/downloads/movies" ]]; then
    echo "Error: this integration expects QBITTORRENT_RADARR_CATEGORY_PATH=/data/downloads/movies" >&2
    echo "       because FileSecurityManager and the coordinator are mounted for that layout." >&2
    exit 1
fi

if [[ "$SONARR_CATEGORY" == "$RADARR_CATEGORY" ]]; then
    echo "Error: Sonarr and Radarr must use different qBittorrent categories." >&2
    exit 1
fi

on_error() {
    local code=$?
    echo >&2
    echo "Deployment failed (exit $code). Current container state:" >&2
    docker compose ps >&2 || true
    echo "The failing setup step should have printed service-specific diagnostics above." >&2
    exit "$code"
}
trap on_error ERR

echo "Creating project directories..."
mkdir -p \
    config/sonarr \
    config/radarr \
    config/qbittorrent \
    config/gluetun \
    config/prowlarr \
    data/downloads/incomplete \
    data/downloads/tv \
    data/downloads/movies \
    data/media/tv \
    data/media/movies \
    runtime/coordinator

# FileSecurityManager runs with PGID as a supplementary group. Keep completed
# roots group-writable and setgid so descendants inherit the cooperative group.
chmod 2775 data/downloads/tv data/downloads/movies

echo "Validating Compose configuration..."
docker compose config --quiet

# Never let an old coordinator process downloads while bootstrap settings are
# being changed. The coordinator is also profile-gated in compose.yaml so a
# plain `docker compose up` on a fresh checkout will not start it accidentally.
docker compose stop coordinator >/dev/null 2>&1 || true

echo "Starting base services..."
docker compose up -d gluetun sonarr radarr qbittorrent prowlarr file-security

echo "Running deterministic application configuration..."
bash scripts/configure.sh

echo "Running final cross-service verification..."
bash scripts/verify-stack.sh

echo "Building and starting the security coordinator LAST..."
docker compose --profile runtime up -d --build --force-recreate coordinator

trap - ERR

echo
echo "Torrent stack deployment completed successfully."
echo
docker compose --profile runtime ps
