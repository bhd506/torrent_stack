#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

# shellcheck disable=SC1091
source scripts/lib/common.sh

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' '<Config><ApiKey>abc123</ApiKey></Config>' >"$TMP"
[[ "$(extract_api_key "$TMP")" == "abc123" ]] || {
    echo "Error: shared API-key extraction helper failed" >&2
    exit 1
}

# Regression guards for the bootstrap bugs already encountered in live testing.
if grep -RInE '^\s*until\b|while[[:space:]]+true' \
    scripts/setup/configure-sonarr.sh scripts/setup/configure-radarr.sh scripts/setup/configure-prowlarr.sh scripts/setup/configure-qbittorrent.sh >/dev/null; then
    echo "Error: unbounded bootstrap loop reintroduced" >&2
    exit 1
fi

grep -q 'scripts/verify/wait-for-services.sh' scripts/setup/configure.sh
grep -q 'profiles: \["runtime"\]' compose.yaml
grep -q 'security coordinator LAST' run.sh
grep -q '/api/v2/app/preferences' services/coordinator/coordinator.py
if grep -q 'cookie.name == "SID"' services/coordinator/coordinator.py; then
    echo "Error: hard-coded qBittorrent SID cookie assumption reintroduced" >&2
    exit 1
fi
if grep -q 'has_session_cookie' scripts/setup/configure-qbittorrent.sh; then
    echo "Error: qBittorrent bootstrap still depends on a cookie name" >&2
    exit 1
fi

grep -q 'QBITTORRENT_AUTH_RETRY_SECONDS' services/coordinator/coordinator.py
grep -q 'CHANGE_THIS_QBITTORRENT_PASSWORD' .env.example

a="$(grep -n 'scripts/setup/configure-qbittorrent.sh' scripts/setup/configure.sh | head -n1 | cut -d: -f1)"
b="$(grep -n 'scripts/setup/configure-sonarr.sh' scripts/setup/configure.sh | head -n1 | cut -d: -f1)"
(( a < b )) || {
    echo "Error: qBittorrent must be configured before Sonarr download-client linking" >&2
    exit 1
}

for service in sonarr radarr prowlarr qbittorrent file-security; do
    grep -q "$service" scripts/verify/wait-for-services.sh || {
        echo "Error: wait-for-services does not cover $service" >&2
        exit 1
    }
done

printf '%s\n' "Bootstrap regression checks passed."
