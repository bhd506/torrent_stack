#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

for command_name in curl docker sed; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

STARTUP_TIMEOUT_SECONDS="${STACK_STARTUP_TIMEOUT_SECONDS:-180}"
if [[ ! "$STARTUP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( STARTUP_TIMEOUT_SECONDS < 1 )); then
    echo "Error: STACK_STARTUP_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 1
fi

SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"
RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
QBITTORRENT_URL="${QBITTORRENT_URL:-http://127.0.0.1:${WEBUI_PORT:-8080}}"
FILE_SECURITY_HOST_URL="${FILE_SECURITY_HOST_URL:-http://127.0.0.1:${FILE_SECURITY_HOST_PORT:-8081}}"

SONARR_CONFIG_FILE="${SONARR_CONFIG_FILE:-$PROJECT_ROOT/state/sonarr/config.xml}"
RADARR_CONFIG_FILE="${RADARR_CONFIG_FILE:-$PROJECT_ROOT/state/radarr/config.xml}"
PROWLARR_CONFIG_FILE="${PROWLARR_CONFIG_FILE:-$PROJECT_ROOT/state/prowlarr/config.xml}"

declare -A ready=(
    [sonarr]=false
    [radarr]=false
    [prowlarr]=false
    [qbittorrent]=false
    [file-security]=false
)

api_key_ready() {
    local file="$1"
    local url="$2"
    local endpoint="$3"
    local key
    key="$(extract_api_key "$file" 2>/dev/null || true)"
    [[ -n "$key" ]] || return 1
    curl -fsS --connect-timeout 2 --max-time 5 -H "X-Api-Key: $key" \
        "${url%/}${endpoint}" >/dev/null 2>&1
}

qbit_http_ready() {
    local status
    status="$(curl -sS --connect-timeout 2 --max-time 4 -o /dev/null -w '%{http_code}' \
        "${QBITTORRENT_URL%/}/" 2>/dev/null || true)"
    [[ "$status" =~ ^[234][0-9][0-9]$ ]]
}

fsm_ready() {
    curl -fsS --connect-timeout 2 --max-time 5 \
        "${FILE_SECURITY_HOST_URL%/}/api/v1/health" >/dev/null 2>&1
}

cd "$PROJECT_ROOT"
echo "Waiting for all base services to become genuinely ready (timeout ${STARTUP_TIMEOUT_SECONDS}s)..."

for ((second = 1; second <= STARTUP_TIMEOUT_SECONDS; second++)); do
    for service in sonarr radarr prowlarr qbittorrent file-security; do
        fail_if_service_terminal "$service" "$service" || exit 1
    done

    if [[ "${ready[sonarr]}" != true ]] && api_key_ready "$SONARR_CONFIG_FILE" "$SONARR_URL" "/api/v3/system/status"; then
        ready[sonarr]=true
    fi
    if [[ "${ready[radarr]}" != true ]] && api_key_ready "$RADARR_CONFIG_FILE" "$RADARR_URL" "/api/v3/system/status"; then
        ready[radarr]=true
    fi
    if [[ "${ready[prowlarr]}" != true ]] && api_key_ready "$PROWLARR_CONFIG_FILE" "$PROWLARR_URL" "/api/v1/system/status"; then
        ready[prowlarr]=true
    fi
    if [[ "${ready[qbittorrent]}" != true ]] && qbit_http_ready; then
        ready[qbittorrent]=true
    fi
    if [[ "${ready[file-security]}" != true ]] && fsm_ready; then
        ready[file-security]=true
    fi

    if [[ "${ready[sonarr]}" == true && "${ready[radarr]}" == true && \
          "${ready[prowlarr]}" == true && "${ready[qbittorrent]}" == true && \
          "${ready[file-security]}" == true ]]; then
        echo "All base services are ready."
        exit 0
    fi

    if (( second == 1 || second % 10 == 0 )); then
        pending=()
        for service in sonarr radarr prowlarr qbittorrent file-security; do
            [[ "${ready[$service]}" == true ]] || pending+=("$service($(service_state "$service"))")
        done
        echo "Still waiting (${second}s): ${pending[*]}"
    fi

    sleep 1
done

echo "Error: base services did not all become ready within ${STARTUP_TIMEOUT_SECONDS}s" >&2
for service in sonarr radarr prowlarr qbittorrent file-security; do
    if [[ "${ready[$service]}" != true ]]; then
        print_service_diagnostics "$service" "$service"
    fi
done
exit 1
