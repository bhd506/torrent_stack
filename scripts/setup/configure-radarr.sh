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

for command_name in curl docker jq sed; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

: "${RADARR_USERNAME:?RADARR_USERNAME is missing from .env}"
: "${RADARR_PASSWORD:?RADARR_PASSWORD is missing from .env}"

RADARR_SERVICE="${RADARR_SERVICE:-radarr}"
RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
RADARR_URL="${RADARR_URL%/}"
RADARR_CONFIG_FILE="${RADARR_CONFIG_FILE:-$PROJECT_ROOT/state/radarr/config.xml}"
RADARR_WAIT_SECONDS="${RADARR_WAIT_SECONDS:-${STACK_SERVICE_WAIT_SECONDS:-120}}"
ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/data/media/movies}"

if [[ ! "$RADARR_WAIT_SECONDS" =~ ^[0-9]+$ ]] || (( RADARR_WAIT_SECONDS < 1 )); then
    echo "Error: RADARR_WAIT_SECONDS must be a positive integer" >&2
    exit 1
fi

cd "$PROJECT_ROOT"
docker compose up -d "$RADARR_SERVICE" >/dev/null

API_KEY="$(wait_for_arr_api \
    "$RADARR_SERVICE" \
    "Radarr" \
    "$RADARR_URL" \
    "$RADARR_CONFIG_FILE" \
    "/api/v3/system/status" \
    "$RADARR_WAIT_SECONDS")"

echo "Configuring Radarr authentication..."
CURRENT_CONFIG="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/config/host")"
UPDATED_CONFIG="$(
    jq \
        --arg username "$RADARR_USERNAME" \
        --arg password "$RADARR_PASSWORD" \
        '
          .authenticationMethod = "forms"
          | .authenticationRequired = "enabled"
          | .username = $username
          | .password = $password
          | .passwordConfirmation = $password
        ' <<<"$CURRENT_CONFIG"
)"

curl -fsS \
    -X PUT \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "$UPDATED_CONFIG" \
    "$RADARR_URL/api/v3/config/host" >/dev/null

VERIFY_HOST_CONFIG="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/config/host")"
if ! jq -e \
    --arg username "$RADARR_USERNAME" \
    '.authenticationMethod == "forms" and .authenticationRequired == "enabled" and .username == $username' \
    <<<"$VERIFY_HOST_CONFIG" >/dev/null; then
    echo "Error: Radarr authentication settings did not verify" >&2
    exit 1
fi

echo "Checking Radarr root folder..."
ROOT_FOLDERS="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/rootfolder")"
if jq -e --arg path "$ROOT_FOLDER" \
    'any(.[]; (.path | rtrimstr("/")) == ($path | rtrimstr("/")))' \
    <<<"$ROOT_FOLDERS" >/dev/null; then
    echo "Root folder already configured: $ROOT_FOLDER"
else
    echo "Creating root folder: $ROOT_FOLDER"
    curl -fsS \
        -X POST \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        --data "$(jq -n --arg path "$ROOT_FOLDER" '{path: $path}')" \
        "$RADARR_URL/api/v3/rootfolder" >/dev/null
fi

ROOT_FOLDERS="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/rootfolder")"
if ! jq -e --arg path "$ROOT_FOLDER" \
    'any(.[]; (.path | rtrimstr("/")) == ($path | rtrimstr("/")))' \
    <<<"$ROOT_FOLDERS" >/dev/null; then
    echo "Error: Radarr root folder did not verify: $ROOT_FOLDER" >&2
    exit 1
fi

echo "Disabling automatic completed-download import..."
DOWNLOAD_CLIENT_CONFIG="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/config/downloadclient")"
UPDATED_DOWNLOAD_CLIENT_CONFIG="$(jq '.enableCompletedDownloadHandling = false' <<<"$DOWNLOAD_CLIENT_CONFIG")"
curl -fsS \
    -X PUT \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "$UPDATED_DOWNLOAD_CLIENT_CONFIG" \
    "$RADARR_URL/api/v3/config/downloadclient" >/dev/null
VERIFY_DOWNLOAD_CLIENT_CONFIG="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/config/downloadclient")"
if ! jq -e '.enableCompletedDownloadHandling == false' <<<"$VERIFY_DOWNLOAD_CLIENT_CONFIG" >/dev/null; then
    echo "Error: Radarr completed download handling was not disabled" >&2
    exit 1
fi

echo "Ensuring hardlink-capable copy imports are enabled..."
MEDIA_MANAGEMENT_CONFIG="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/config/mediamanagement")"
UPDATED_MEDIA_MANAGEMENT_CONFIG="$(jq '.copyUsingHardlinks = true' <<<"$MEDIA_MANAGEMENT_CONFIG")"
curl -fsS \
    -X PUT \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "$UPDATED_MEDIA_MANAGEMENT_CONFIG" \
    "$RADARR_URL/api/v3/config/mediamanagement" >/dev/null
VERIFY_MEDIA_MANAGEMENT_CONFIG="$(curl -fsS -H "X-Api-Key: $API_KEY" "$RADARR_URL/api/v3/config/mediamanagement")"
if ! jq -e '.copyUsingHardlinks == true' <<<"$VERIFY_MEDIA_MANAGEMENT_CONFIG" >/dev/null; then
    echo "Error: Radarr hardlink setting was not enabled" >&2
    exit 1
fi

echo
echo "Radarr configuration completed successfully."
echo "  API:                  $RADARR_URL"
echo "  Root folder:          $ROOT_FOLDER"
echo "  Completed handling:   disabled (coordinator gated)"
echo "  Hardlink-capable copy: enabled"
