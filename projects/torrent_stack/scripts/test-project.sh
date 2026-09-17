#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

printf '%s\n' "Checking shell syntax..."
bash -n run.sh
for script in scripts/*.sh scripts/lib/*.sh; do
    bash -n "$script"
done

printf '%s\n' "Checking bootstrap regressions..."
bash scripts/test-bootstrap.sh

printf '%s\n' "Checking namespaced environment variables..."
if grep -RInE '^[[:space:]]*(USERNAME|PASSWORD)=' .env.example compose.yaml scripts run.sh >/dev/null; then
    echo "Error: generic USERNAME/PASSWORD variables are still present" >&2
    exit 1
fi
for required in \
    SONARR_USERNAME SONARR_PASSWORD \
    RADARR_USERNAME RADARR_PASSWORD \
    PROWLARR_USERNAME PROWLARR_PASSWORD \
    QBITTORRENT_USERNAME QBITTORRENT_PASSWORD; do
    grep -q "^${required}=" .env.example || {
        echo "Error: missing ${required} in .env.example" >&2
        exit 1
    }
done

printf '%s\n' "Checking qBittorrent category routing configuration..."
for setting in \
    auto_tmm_enabled \
    torrent_changed_tmm_enabled \
    save_path_changed_tmm_enabled \
    category_changed_tmm_enabled \
    use_category_paths_in_manual_mode; do
    grep -q "${setting}: true" scripts/configure-qbittorrent.sh || {
        echo "Error: qBittorrent setting ${setting} is not enabled" >&2
        exit 1
    }
done
grep -q 'QBITTORRENT_SONARR_CATEGORY_PATH=.*/data/downloads/tv' .env.example
grep -q 'QBITTORRENT_RADARR_CATEGORY_PATH=.*/data/downloads/movies' .env.example
grep -q '/api/v2/torrents/setAutoManagement' scripts/configure-qbittorrent.sh

printf '%s\n' "Checking Gluetun/PIA qBittorrent isolation..."
grep -q 'VPN_SERVICE_PROVIDER: "private internet access"' compose.yaml
grep -q 'network_mode: "service:gluetun"' compose.yaml
grep -q 'QBITTORRENT_URL: "http://gluetun:8080"' compose.yaml
grep -q '^PIA_OPENVPN_USER=' .env.example
grep -q '^PIA_OPENVPN_PASSWORD=' .env.example
grep -q 'VPN_PORT_FORWARDING_UP_COMMAND' compose.yaml
grep -q 'bypass_local_auth: true' scripts/configure-qbittorrent.sh
if awk '/^  qbittorrent:/{in_qbit=1;next} /^  [a-zA-Z0-9_-]+:/{in_qbit=0} in_qbit && /^[[:space:]]+ports:/{found=1} END{exit found?0:1}' compose.yaml; then
    echo "Error: qBittorrent must not publish ports directly when using Gluetun" >&2
    exit 1
fi

printf '%s\n' "Checking Python syntax and unit tests..."
python3 -m py_compile coordinator/coordinator.py coordinator/test_coordinator.py
python3 -m unittest discover -s coordinator -p 'test_*.py' -v

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf '%s\n' "Checking Docker Compose configuration..."
    docker compose --env-file .env.example config --quiet
else
    printf '%s\n' "Docker Compose not available; skipped compose validation."
fi

printf '%s\n' "Project checks passed."
