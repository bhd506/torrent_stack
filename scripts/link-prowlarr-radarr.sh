#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
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
source "$SCRIPT_DIR/lib/common.sh"

for command_name in curl jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name" >&2
        exit 1
    fi
done

PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
PROWLARR_URL="${PROWLARR_URL%/}"
RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
RADARR_URL="${RADARR_URL%/}"
PROWLARR_INTERNAL_URL="${PROWLARR_INTERNAL_URL:-http://prowlarr:9696}"
PROWLARR_INTERNAL_URL="${PROWLARR_INTERNAL_URL%/}"
RADARR_INTERNAL_URL="${RADARR_INTERNAL_URL:-http://radarr:7878}"
RADARR_INTERNAL_URL="${RADARR_INTERNAL_URL%/}"
PROWLARR_CONFIG_FILE="${PROWLARR_CONFIG_FILE:-$PROJECT_ROOT/config/prowlarr/config.xml}"
RADARR_CONFIG_FILE="${RADARR_CONFIG_FILE:-$PROJECT_ROOT/config/radarr/config.xml}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

if [[ ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || (( WAIT_SECONDS < 1 )); then
    echo "Error: WAIT_SECONDS must be a positive integer" >&2
    exit 1
fi

extract_api_key() {
    sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$1" | head -n 1
}

if [[ ! -f "$PROWLARR_CONFIG_FILE" || ! -f "$RADARR_CONFIG_FILE" ]]; then
    echo "Error: Prowlarr or Radarr config.xml is missing" >&2
    exit 1
fi

PROWLARR_API_KEY="$(extract_api_key "$PROWLARR_CONFIG_FILE")"
RADARR_API_KEY="$(extract_api_key "$RADARR_CONFIG_FILE")"

if [[ -z "$PROWLARR_API_KEY" || -z "$RADARR_API_KEY" ]]; then
    echo "Error: Prowlarr or Radarr API key is missing" >&2
    exit 1
fi

prowlarr_get() {
    curl --fail-with-body -sS \
        -H "X-Api-Key: $PROWLARR_API_KEY" \
        "$PROWLARR_URL$1"
}

prowlarr_send() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"
    curl --fail-with-body -sS \
        -X "$method" \
        -H "X-Api-Key: $PROWLARR_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$PROWLARR_URL$endpoint"
}

echo "Waiting for Prowlarr and Radarr..."
ready=false
for ((second = 1; second <= WAIT_SECONDS; second++)); do
    if curl -fsS -H "X-Api-Key: $PROWLARR_API_KEY" \
        "$PROWLARR_URL/api/v1/system/status" >/dev/null 2>&1 &&
       curl -fsS -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/system/status" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done

if [[ "$ready" != true ]]; then
    echo "Error: Prowlarr or Radarr did not become ready" >&2
    print_service_diagnostics "prowlarr" "Prowlarr"
    print_service_diagnostics "radarr" "Radarr"
    exit 1
fi

APPLICATIONS="$(prowlarr_get "/api/v1/applications")"
EXISTING="$(
    jq '[.[] | select(.implementation == "Radarr")] | first // empty' \
        <<<"$APPLICATIONS"
)"

if [[ -n "$EXISTING" ]]; then
    PAYLOAD="$EXISTING"
    APPLICATION_ID="$(jq -r '.id' <<<"$EXISTING")"
    METHOD="PUT"
    ENDPOINT="/api/v1/applications/$APPLICATION_ID"
else
    SCHEMAS="$(prowlarr_get "/api/v1/applications/schema")"
    PAYLOAD="$(
        jq '[.[] | select(.implementation == "Radarr")] | first // empty' \
            <<<"$SCHEMAS"
    )"
    METHOD="POST"
    ENDPOINT="/api/v1/applications"
fi

if [[ -z "$PAYLOAD" ]]; then
    echo "Error: Radarr application schema was not found in Prowlarr" >&2
    exit 1
fi

PAYLOAD="$(
    jq \
        --arg prowlarr_url "$PROWLARR_INTERNAL_URL" \
        --arg radarr_url "$RADARR_INTERNAL_URL" \
        --arg radarr_api_key "$RADARR_API_KEY" \
        '
            .name = "Radarr"
            | .syncLevel = "fullSync"
            | .fields |= map(
                if .name == "prowlarrUrl" then
                    .value = $prowlarr_url
                elif .name == "baseUrl" then
                    .value = $radarr_url
                elif .name == "apiKey" then
                    .value = $radarr_api_key
                elif .name == "authUsername" then
                    .value = ""
                elif .name == "authPassword" then
                    .value = ""
                else
                    .
                end
            )
        ' \
        <<<"$PAYLOAD"
)"

echo "Testing Prowlarr -> Radarr..."
prowlarr_send POST "/api/v1/applications/test" "$PAYLOAD" >/dev/null

echo "Saving the Radarr application in Prowlarr..."
prowlarr_send "$METHOD" "$ENDPOINT" "$PAYLOAD" >/dev/null

SAVED="$(prowlarr_get "/api/v1/applications")"
if ! jq \
    -e \
    --arg prowlarr_url "$PROWLARR_INTERNAL_URL" \
    --arg radarr_url "$RADARR_INTERNAL_URL" \
    '
        def field($name):
            [.fields[] | select(.name == $name) | .value][0];

        any(
            .[];
            .implementation == "Radarr"
            and .syncLevel == "fullSync"
            and field("prowlarrUrl") == $prowlarr_url
            and field("baseUrl") == $radarr_url
        )
    ' \
    <<<"$SAVED" \
    >/dev/null; then
    echo "Error: saved Radarr application did not verify" >&2
    exit 1
fi

echo
echo "Prowlarr is linked to Radarr."
echo "  Prowlarr URL seen by Radarr: $PROWLARR_INTERNAL_URL"
echo "  Radarr URL seen by Prowlarr: $RADARR_INTERNAL_URL"
echo "  Sync level:                  fullSync"
