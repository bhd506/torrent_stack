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

for command_name in curl docker jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name" >&2
        exit 1
    fi
done

USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"

PROWLARR_SERVICE="${PROWLARR_SERVICE:-prowlarr}"
PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
PROWLARR_URL="${PROWLARR_URL%/}"
PROWLARR_CONFIG_FILE="${PROWLARR_CONFIG_FILE:-$PROJECT_ROOT/config/prowlarr/config.xml}"
PROWLARR_WAIT_SECONDS="${PROWLARR_WAIT_SECONDS:-120}"

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "Error: USERNAME and PASSWORD must be set in $ENV_FILE" >&2
    exit 1
fi

if [[ ! "$PROWLARR_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Error: PROWLARR_WAIT_SECONDS must be numeric" >&2
    exit 1
fi

if (( PROWLARR_WAIT_SECONDS < 1 )); then
    echo "Error: PROWLARR_WAIT_SECONDS must be greater than zero" >&2
    exit 1
fi

extract_api_key() {
    sed -n \
        's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' \
        "$PROWLARR_CONFIG_FILE" |
        head -n 1
}

cd "$PROJECT_ROOT"

echo "Starting Prowlarr..."

docker compose up -d "$PROWLARR_SERVICE"

echo "Waiting for Prowlarr to create its configuration..."

API_KEY=""

for ((second = 1; second <= PROWLARR_WAIT_SECONDS; second++)); do
    if [[ -f "$PROWLARR_CONFIG_FILE" ]]; then
        API_KEY="$(extract_api_key)"

        if [[ -n "$API_KEY" ]]; then
            break
        fi
    fi

    sleep 1
done

if [[ -z "$API_KEY" ]]; then
    echo "Error: Prowlarr API key was not found in:" >&2
    echo "  $PROWLARR_CONFIG_FILE" >&2
    echo "Inspect startup with:" >&2
    echo "  docker compose logs $PROWLARR_SERVICE" >&2
    exit 1
fi

echo "Waiting for the Prowlarr API at $PROWLARR_URL..."

api_ready=false

for ((second = 1; second <= PROWLARR_WAIT_SECONDS; second++)); do
    if curl \
        -fsS \
        --connect-timeout 2 \
        --max-time 5 \
        -H "X-Api-Key: $API_KEY" \
        "$PROWLARR_URL/api/v1/system/status" \
        >/dev/null 2>&1; then

        api_ready=true
        break
    fi

    sleep 1
done

if [[ "$api_ready" != true ]]; then
    echo "Error: Prowlarr API did not become ready" >&2
    echo "Inspect startup with:" >&2
    echo "  docker compose logs $PROWLARR_SERVICE" >&2
    exit 1
fi

echo "Reading current Prowlarr host configuration..."

HOST_CONFIG="$(
    curl \
        -fsS \
        --connect-timeout 5 \
        --max-time 30 \
        -H "X-Api-Key: $API_KEY" \
        "$PROWLARR_URL/api/v1/config/host"
)"

HOST_ID="$(
    jq -r '.id // 1' <<<"$HOST_CONFIG"
)"

UPDATED_CONFIG="$(
    jq \
        --arg username "$USERNAME" \
        --arg password "$PASSWORD" \
        '
            .authenticationMethod = "forms"
            | .authenticationRequired = "enabled"
            | .username = $username
            | .password = $password
            | .passwordConfirmation = $password
        ' \
        <<<"$HOST_CONFIG"
)"

echo "Applying Prowlarr authentication settings..."

curl \
    -fsS \
    --connect-timeout 5 \
    --max-time 30 \
    -X PUT \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    --data "$UPDATED_CONFIG" \
    "$PROWLARR_URL/api/v1/config/host/$HOST_ID" \
    >/dev/null

echo "Verifying Prowlarr configuration..."

verified=false

for ((attempt = 1; attempt <= 30; attempt++)); do
    CURRENT_CONFIG="$(
        curl \
            -fsS \
            --connect-timeout 5 \
            --max-time 15 \
            -H "X-Api-Key: $API_KEY" \
            "$PROWLARR_URL/api/v1/config/host" \
            2>/dev/null \
            || true
    )"

    if jq \
        -e \
        --arg username "$USERNAME" \
        '
            .authenticationMethod == "forms"
            and .authenticationRequired == "enabled"
            and .username == $username
        ' \
        <<<"$CURRENT_CONFIG" \
        >/dev/null 2>&1; then

        verified=true
        break
    fi

    sleep 1
done

if [[ "$verified" != true ]]; then
    echo "Error: Prowlarr configuration verification failed" >&2
    exit 1
fi

echo
echo "Prowlarr configuration completed successfully."
echo "  WebUI:    $PROWLARR_URL"
echo "  Username: $USERNAME"
echo "  Auth:     forms, required"
