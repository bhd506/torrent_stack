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

for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-}"

RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
RADARR_URL="${RADARR_URL%/}"
RADARR_CONFIG_FILE="${RADARR_CONFIG_FILE:-$PROJECT_ROOT/state/radarr/config.xml}"

QBITTORRENT_HOST="${QBITTORRENT_HOST:-gluetun}"
QBITTORRENT_WEBUI_PORT="${QBITTORRENT_WEBUI_PORT:-8080}"
QBITTORRENT_RADARR_CATEGORY="${QBITTORRENT_RADARR_CATEGORY:-radarr}"

if [[ -z "$QBITTORRENT_USERNAME" || -z "$QBITTORRENT_PASSWORD" ]]; then
    echo "Error: QBITTORRENT_USERNAME and QBITTORRENT_PASSWORD must be set in $ENV_FILE" >&2
    exit 1
fi

if [[ ! "$QBITTORRENT_WEBUI_PORT" =~ ^[0-9]+$ ]] ||
   (( QBITTORRENT_WEBUI_PORT < 1 || QBITTORRENT_WEBUI_PORT > 65535 )); then
    echo "Error: QBITTORRENT_WEBUI_PORT must be a port between 1 and 65535" >&2
    exit 1
fi

if [[ ! -f "$RADARR_CONFIG_FILE" ]]; then
    echo "Error: Radarr config file not found: $RADARR_CONFIG_FILE" >&2
    exit 1
fi

API_KEY="$(
    sed -n \
        's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' \
        "$RADARR_CONFIG_FILE" |
    head -n 1
)"

if [[ -z "$API_KEY" ]]; then
    echo "Error: Radarr API key not found in $RADARR_CONFIG_FILE" >&2
    exit 1
fi

radarr_get() {
    curl --fail-with-body -sS \
        -H "X-Api-Key: $API_KEY" \
        "$RADARR_URL$1"
}

radarr_send() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"

    curl --fail-with-body -sS \
        -X "$method" \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$RADARR_URL$endpoint"
}

echo "Waiting for Radarr..."

for attempt in {1..60}; do
    if radarr_get "/api/v3/system/status" >/dev/null 2>&1; then
        break
    fi

    if (( attempt == 60 )); then
        echo "Error: Radarr did not become ready" >&2
        print_service_diagnostics "radarr" "Radarr"
        exit 1
    fi

    sleep 2
done

echo "Reading existing Radarr download clients..."

CLIENTS="$(radarr_get "/api/v3/downloadclient")"
EXISTING="$(
    jq '[.[] | select(.implementation == "QBittorrent")] | first // empty' \
        <<<"$CLIENTS"
)"

if [[ -n "$EXISTING" ]]; then
    PAYLOAD="$EXISTING"
    CLIENT_ID="$(jq -r '.id' <<<"$EXISTING")"
    METHOD="PUT"
    ENDPOINT="/api/v3/downloadclient/$CLIENT_ID"
else
    SCHEMAS="$(radarr_get "/api/v3/downloadclient/schema")"
    PAYLOAD="$(
        jq '[.[] | select(.implementation == "QBittorrent")] | first // empty' \
            <<<"$SCHEMAS"
    )"
    METHOD="POST"
    ENDPOINT="/api/v3/downloadclient"
fi

if [[ -z "$PAYLOAD" ]]; then
    echo "Error: qBittorrent download-client schema was not found in Radarr" >&2
    exit 1
fi

PAYLOAD="$(
    jq \
        --arg host "$QBITTORRENT_HOST" \
        --arg username "$QBITTORRENT_USERNAME" \
        --arg password "$QBITTORRENT_PASSWORD" \
        --arg category "$QBITTORRENT_RADARR_CATEGORY" \
        --argjson port "$QBITTORRENT_WEBUI_PORT" \
        '
            .name = "qBittorrent"
            | .enable = true
            | .fields |= map(
                if .name == "host" then
                    .value = $host
                elif .name == "port" then
                    .value = $port
                elif .name == "useSsl" then
                    .value = false
                elif .name == "urlBase" then
                    .value = ""
                elif .name == "apiKey" then
                    .value = ""
                elif .name == "username" then
                    .value = $username
                elif .name == "password" then
                    .value = $password
                elif .name == "movieCategory" then
                    .value = $category
                else
                    .
                end
            )
        ' \
        <<<"$PAYLOAD"
)"

echo "Testing Radarr -> qBittorrent..."
radarr_send POST "/api/v3/downloadclient/test" "$PAYLOAD" >/dev/null

echo "Saving the qBittorrent download client in Radarr..."
radarr_send "$METHOD" "$ENDPOINT" "$PAYLOAD" >/dev/null

echo "Verifying the saved download client..."
SAVED="$(radarr_get "/api/v3/downloadclient")"

if ! jq \
    -e \
    --arg host "$QBITTORRENT_HOST" \
    --arg category "$QBITTORRENT_RADARR_CATEGORY" \
    --argjson port "$QBITTORRENT_WEBUI_PORT" \
    '
        def field($name):
            [.fields[] | select(.name == $name) | .value][0];

        any(
            .[];
            .implementation == "QBittorrent"
            and .enable == true
            and field("host") == $host
            and field("port") == $port
            and field("movieCategory") == $category
        )
    ' \
    <<<"$SAVED" \
    >/dev/null; then

    echo "Error: saved Radarr qBittorrent client did not verify" >&2
    exit 1
fi

echo
echo "Radarr is linked to qBittorrent."
echo "  Host:     $QBITTORRENT_HOST"
echo "  Port:     $QBITTORRENT_WEBUI_PORT"
echo "  Category: $QBITTORRENT_RADARR_CATEGORY"
