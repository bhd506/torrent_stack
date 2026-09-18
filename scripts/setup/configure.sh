#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

CONFIGURATION_SCRIPTS=(
    # qBittorrent first: fresh installs may have a temporary WebUI password and
    # the *arr download-client tests depend on its permanent credentials.
    "scripts/setup/configure-qbittorrent.sh"
    "scripts/setup/configure-sonarr.sh"
    "scripts/setup/configure-radarr.sh"
    "scripts/setup/configure-prowlarr.sh"
    "scripts/setup/link-sonarr-qbittorrent.sh"
    "scripts/setup/link-radarr-qbittorrent.sh"
    "scripts/setup/link-prowlarr-sonarr.sh"
    "scripts/setup/link-prowlarr-radarr.sh"
    "scripts/setup/configure-prowlarr-indexers.sh"
)

echo "Checking configuration scripts..."
for script in "scripts/verify/wait-for-services.sh" "${CONFIGURATION_SCRIPTS[@]}"; do
    if [[ ! -f "$script" ]]; then
        echo "Error: required script not found: $script" >&2
        exit 1
    fi
    bash -n "$script"
done

# This makes configure.sh safe to invoke directly as well as through run.sh.
echo "Ensuring base services are started..."
docker compose up -d gluetun sonarr radarr qbittorrent prowlarr file-security

bash scripts/verify/wait-for-services.sh

for script in "${CONFIGURATION_SCRIPTS[@]}"; do
    echo
    echo "============================================================"
    echo "Running: $script"
    echo "============================================================"
    bash "$script"
done

echo
echo "Application configuration completed successfully."
