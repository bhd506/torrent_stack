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

for command_name in curl docker jq sed; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

: "${PROWLARR_USERNAME:?PROWLARR_USERNAME is missing from .env}"
: "${PROWLARR_PASSWORD:?PROWLARR_PASSWORD is missing from .env}"

PROWLARR_SERVICE="${PROWLARR_SERVICE:-prowlarr}"
PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
PROWLARR_URL="${PROWLARR_URL%/}"
PROWLARR_CONFIG_FILE="${PROWLARR_CONFIG_FILE:-$PROJECT_ROOT/config/prowlarr/config.xml}"
PROWLARR_WAIT_SECONDS="${PROWLARR_WAIT_SECONDS:-${STACK_SERVICE_WAIT_SECONDS:-120}}"

if [[ ! "$PROWLARR_WAIT_SECONDS" =~ ^[0-9]+$ ]] || (( PROWLARR_WAIT_SECONDS < 1 )); then
    echo "Error: PROWLARR_WAIT_SECONDS must be a positive integer" >&2
    exit 1
fi

cd "$PROJECT_ROOT"
docker compose up -d "$PROWLARR_SERVICE" >/dev/null

API_KEY="$(wait_for_arr_api \
    "$PROWLARR_SERVICE" \
    "Prowlarr" \
    "$PROWLARR_URL" \
    "$PROWLARR_CONFIG_FILE" \
    "/api/v1/system/status" \
    "$PROWLARR_WAIT_SECONDS")"

echo "Reading current Prowlarr host configuration..."
HOST_CONFIG="$(curl -fsS --connect-timeout 5 --max-time 30 \
    -H "X-Api-Key: $API_KEY" "$PROWLARR_URL/api/v1/config/host")"
HOST_ID="$(jq -r '.id // 1' <<<"$HOST_CONFIG")"
UPDATED_CONFIG="$(
    jq \
        --arg username "$PROWLARR_USERNAME" \
        --arg password "$PROWLARR_PASSWORD" \
        '
            .authenticationMethod = "forms"
            | .authenticationRequired = "enabled"
            | .username = $username
            | .password = $password
            | .passwordConfirmation = $password
        ' <<<"$HOST_CONFIG"
)"

echo "Applying Prowlarr authentication settings..."
curl -fsS --connect-timeout 5 --max-time 30 \
    -X PUT \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    --data "$UPDATED_CONFIG" \
    "$PROWLARR_URL/api/v1/config/host/$HOST_ID" >/dev/null

echo "Verifying Prowlarr configuration..."
CURRENT_CONFIG="$(curl -fsS --connect-timeout 5 --max-time 30 \
    -H "X-Api-Key: $API_KEY" "$PROWLARR_URL/api/v1/config/host")"
if ! jq -e \
    --arg username "$PROWLARR_USERNAME" \
    '.authenticationMethod == "forms" and .authenticationRequired == "enabled" and .username == $username' \
    <<<"$CURRENT_CONFIG" >/dev/null; then
    echo "Error: Prowlarr authentication settings did not verify" >&2
    exit 1
fi

echo
echo "Prowlarr configuration completed successfully."
echo "  WebUI:    $PROWLARR_URL"
echo "  Username: $PROWLARR_USERNAME"
echo "  Auth:     forms, required"
