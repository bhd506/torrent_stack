#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

CONFIGURATION_SCRIPTS=(
    "scripts/configure-sonarr.sh"
    "scripts/configure-qbittorrent.sh"
    "scripts/configure-prowlarr.sh"
    "scripts/link-sonarr-qbittorrent.sh"
    "scripts/link-prowlarr-sonarr.sh"
    "scripts/configure-prowlarr-indexers.sh"
)

echo "Checking configuration scripts..."

for script in "${CONFIGURATION_SCRIPTS[@]}"; do
    if [[ ! -f "$script" ]]; then
        echo "Error: required script not found: $script" >&2
        exit 1
    fi

    bash -n "$script"
done

for script in "${CONFIGURATION_SCRIPTS[@]}"; do
    echo
    echo "============================================================"
    echo "Running: $script"
    echo "============================================================"

    bash "$script"
done

echo
echo "Application configuration completed successfully."
