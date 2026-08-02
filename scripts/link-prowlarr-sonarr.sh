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

for command_name in curl jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name" >&2
        exit 1
    fi
done

PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
PROWLARR_URL="${PROWLARR_URL%/}"

SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"
SONARR_URL="${SONARR_URL%/}"

PROWLARR_INTERNAL_URL="${PROWLARR_INTERNAL_URL:-http://prowlarr:9696}"
PROWLARR_INTERNAL_URL="${PROWLARR_INTERNAL_URL%/}"

SONARR_INTERNAL_URL="${SONARR_INTERNAL_URL:-http://sonarr:8989}"
SONARR_INTERNAL_URL="${SONARR_INTERNAL_URL%/}"

PROWLARR_CONFIG_FILE="${PROWLARR_CONFIG_FILE:-$PROJECT_ROOT/config/prowlarr/config.xml}"
SONARR_CONFIG_FILE="${SONARR_CONFIG_FILE:-$PROJECT_ROOT/config/sonarr/config.xml}"

WAIT_SECONDS="${WAIT_SECONDS:-120}"

if [[ ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || (( WAIT_SECONDS < 1 )); then
    echo "Error: WAIT_SECONDS must be a positive integer" >&2
    exit 1
fi

extract_api_key() {
    local config_file="$1"

    sed -n \
        's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' \
        "$config_file" |
        head -n 1
}

if [[ ! -f "$PROWLARR_CONFIG_FILE" ]]; then
    echo "Error: Prowlarr config file not found: $PROWLARR_CONFIG_FILE" >&2
    exit 1
fi

if [[ ! -f "$SONARR_CONFIG_FILE" ]]; then
    echo "Error: Sonarr config file not found: $SONARR_CONFIG_FILE" >&2
    exit 1
fi

PROWLARR_API_KEY="$(extract_api_key "$PROWLARR_CONFIG_FILE")"
SONARR_API_KEY="$(extract_api_key "$SONARR_CONFIG_FILE")"

if [[ -z "$PROWLARR_API_KEY" ]]; then
    echo "Error: Prowlarr API key not found in $PROWLARR_CONFIG_FILE" >&2
    exit 1
fi

if [[ -z "$SONARR_API_KEY" ]]; then
    echo "Error: Sonarr API key not found in $SONARR_CONFIG_FILE" >&2
    exit 1
fi

prowlarr_get() {
    local endpoint="$1"

    curl \
        --fail-with-body \
        -sS \
        -H "X-Api-Key: $PROWLARR_API_KEY" \
        "$PROWLARR_URL$endpoint"
}

prowlarr_send() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"

    curl \
        --fail-with-body \
        -sS \
        -X "$method" \
        -H "X-Api-Key: $PROWLARR_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$PROWLARR_URL$endpoint"
}

echo "Waiting for Prowlarr and Sonarr..."

ready=false

for ((second = 1; second <= WAIT_SECONDS; second++)); do
    if curl \
        -fsS \
        -H "X-Api-Key: $PROWLARR_API_KEY" \
        "$PROWLARR_URL/api/v1/system/status" \
        >/dev/null 2>&1 &&
       curl \
        -fsS \
        -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/system/status" \
        >/dev/null 2>&1; then

        ready=true
        break
    fi

    sleep 1
done

if [[ "$ready" != true ]]; then
    echo "Error: Prowlarr or Sonarr did not become ready" >&2
    exit 1
fi

echo "Reading existing Prowlarr applications..."

APPLICATIONS="$(prowlarr_get "/api/v1/applications")"

EXISTING="$(
    jq \
        '[.[] | select(.implementation == "Sonarr")] | first // empty' \
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
        jq \
            '[.[] | select(.implementation == "Sonarr")] | first // empty' \
            <<<"$SCHEMAS"
    )"

    METHOD="POST"
    ENDPOINT="/api/v1/applications"
fi

if [[ -z "$PAYLOAD" ]]; then
    echo "Error: Sonarr application schema was not found in Prowlarr" >&2
    exit 1
fi

PAYLOAD="$(
    jq \
        --arg prowlarr_url "$PROWLARR_INTERNAL_URL" \
        --arg sonarr_url "$SONARR_INTERNAL_URL" \
        --arg sonarr_api_key "$SONARR_API_KEY" \
        '
            .name = "Sonarr"
            | .syncLevel = "fullSync"
            | .fields |= map(
                if .name == "prowlarrUrl" then
                    .value = $prowlarr_url
                elif .name == "baseUrl" then
                    .value = $sonarr_url
                elif .name == "apiKey" then
                    .value = $sonarr_api_key
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

echo "Testing Prowlarr -> Sonarr..."

prowlarr_send \
    POST \
    "/api/v1/applications/test" \
    "$PAYLOAD" \
    >/dev/null

echo "Saving the Sonarr application in Prowlarr..."

prowlarr_send \
    "$METHOD" \
    "$ENDPOINT" \
    "$PAYLOAD" \
    >/dev/null

echo "Verifying the saved application..."

SAVED="$(prowlarr_get "/api/v1/applications")"

if ! jq \
    -e \
    --arg prowlarr_url "$PROWLARR_INTERNAL_URL" \
    --arg sonarr_url "$SONARR_INTERNAL_URL" \
    '
        def field($name):
            [.fields[] | select(.name == $name) | .value][0];

        any(
            .[];
            .implementation == "Sonarr"
            and .syncLevel == "fullSync"
            and field("prowlarrUrl") == $prowlarr_url
            and field("baseUrl") == $sonarr_url
        )
    ' \
    <<<"$SAVED" \
    >/dev/null; then

    echo "Error: saved Sonarr application did not verify" >&2
    exit 1
fi

echo
echo "Prowlarr is linked to Sonarr."
echo "  Prowlarr URL seen by Sonarr: $PROWLARR_INTERNAL_URL"
echo "  Sonarr URL seen by Prowlarr: $SONARR_INTERNAL_URL"
echo "  Sync level:                  fullSync"
