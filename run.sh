#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

fail() {
    echo "Error: $*" >&2
    exit 1
}

if (( EUID == 0 )); then
    fail "do not run this project as root or with sudo; run ./run.sh as your normal Docker-enabled user."
fi

[[ -f .env ]] || fail ".env is missing. Copy .env.example to .env and edit it first."

# Secrets should not be readable by other local users. Tighten an overly broad
# mode automatically; this file is owned by the invoking user on a normal checkout.
chmod go-rwx .env 2>/dev/null || fail "could not secure .env; ensure it is owned by your user."

set -a
# shellcheck disable=SC1091
source .env
set +a

for command_name in docker curl jq sed; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is not available."
docker info >/dev/null 2>&1 || fail "Docker is not reachable by this user. Add your user to the appropriate Docker group/socket ACL instead of running this script with sudo."

required_vars=(
    PUID PGID TZ
    SONARR_USERNAME SONARR_PASSWORD
    RADARR_USERNAME RADARR_PASSWORD
    PROWLARR_USERNAME PROWLARR_PASSWORD
    QBITTORRENT_USERNAME QBITTORRENT_PASSWORD
    PIA_OPENVPN_USER PIA_OPENVPN_PASSWORD
)
for name in "${required_vars[@]}"; do
    [[ -n "${!name:-}" ]] || fail "$name is missing from .env"
done

[[ "$PUID" =~ ^[0-9]+$ ]] || fail "PUID must be numeric"
[[ "$PGID" =~ ^[0-9]+$ ]] || fail "PGID must be numeric"
(( PUID == $(id -u) )) || fail "PUID=$PUID does not match this user's UID ($(id -u)). Use your normal user's UID so host files stay user-owned."
(( PGID == $(id -g) )) || fail "PGID=$PGID does not match this user's primary GID ($(id -g)). Use your normal user's primary GID so host files stay user-owned."

for name in SONARR_PASSWORD RADARR_PASSWORD PROWLARR_PASSWORD QBITTORRENT_PASSWORD PIA_OPENVPN_USER PIA_OPENVPN_PASSWORD; do
    value="${!name}"
    [[ "$value" != CHANGE_THIS_* ]] || fail "$name still contains the .env.example placeholder value."
done

SONARR_CATEGORY="${QBITTORRENT_SONARR_CATEGORY:-sonarr}"
SONARR_PATH="${QBITTORRENT_SONARR_CATEGORY_PATH:-/data/downloads/tv}"
RADARR_CATEGORY="${QBITTORRENT_RADARR_CATEGORY:-radarr}"
RADARR_PATH="${QBITTORRENT_RADARR_CATEGORY_PATH:-/data/downloads/movies}"

[[ "$SONARR_PATH" == "/data/downloads/tv" ]] || fail "QBITTORRENT_SONARR_CATEGORY_PATH must be /data/downloads/tv for this integration."
[[ "$RADARR_PATH" == "/data/downloads/movies" ]] || fail "QBITTORRENT_RADARR_CATEGORY_PATH must be /data/downloads/movies for this integration."
[[ "$SONARR_CATEGORY" != "$RADARR_CATEGORY" ]] || fail "Sonarr and Radarr must use different qBittorrent categories."

on_error() {
    local code=$?
    echo >&2
    echo "Deployment failed (exit $code). Current container state:" >&2
    docker compose --profile runtime ps >&2 || true
    echo "The failing setup step should have printed service-specific diagnostics above." >&2
    exit "$code"
}
trap on_error ERR

ensure_host_layout() {
    echo "Preparing host-owned project directories..."
    mkdir -p \
        state/sonarr \
        state/radarr \
        state/prowlarr \
        state/qbittorrent \
        state/coordinator \
        data/downloads/incomplete \
        data/downloads/tv \
        data/downloads/movies \
        data/media/tv \
        data/media/movies

    # Cooperative group permissions are needed across qBittorrent, the *arr
    # services and FileSecurityManager. setgid makes new descendants retain PGID.
    chmod 2775 data data/downloads data/downloads/incomplete \
        data/downloads/tv data/downloads/movies data/media \
        data/media/tv data/media/movies
    chmod 0755 state
    chmod 0775 state/sonarr state/radarr state/prowlarr state/qbittorrent state/coordinator

    local root_owned
    root_owned="$(find state data -xdev -user 0 -print -quit 2>/dev/null || true)"
    if [[ -n "$root_owned" ]]; then
        fail "root-owned project data already exists at: $root_owned. Fix its ownership once, then rerun without sudo."
    fi
}

ensure_host_layout

echo "Validating Compose configuration..."
docker compose config --quiet

# Never let an old coordinator import while bootstrap settings are changing.
docker compose --profile runtime stop coordinator >/dev/null 2>&1 || true

echo "Starting base services..."
docker compose up -d gluetun sonarr radarr qbittorrent prowlarr file-security

echo "Running deterministic application configuration..."
bash scripts/setup/configure.sh

echo "Running final cross-service verification..."
bash scripts/verify/verify-stack.sh

echo "Building and starting the security coordinator LAST..."
docker compose --profile runtime up -d --build --force-recreate coordinator

# Catch accidental root ownership introduced by a changed image/mount before it
# becomes an unpleasant surprise during normal host-side maintenance.
root_owned="$(find state data -xdev -user 0 -print -quit 2>/dev/null || true)"
[[ -z "$root_owned" ]] || fail "deployment created a root-owned host path: $root_owned"

trap - ERR

echo
echo "Torrent stack deployment completed successfully."
echo
docker compose --profile runtime ps
