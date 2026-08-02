#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
source "$PROJECT_DIR/.env"
set +a

: "${USERNAME:?USERNAME is missing from .env}"
: "${PASSWORD:?PASSWORD is missing from .env}"

SONARR_URL="${SONARR_URL:-http://localhost:8989}"
CONFIG_FILE="$PROJECT_DIR/config/sonarr/config.xml"

echo "Waiting for Sonarr configuration..."

until [[ -f "$CONFIG_FILE" ]] && grep -q '<ApiKey>' "$CONFIG_FILE"; do
    sleep 1
done

API_KEY="$(
    sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$CONFIG_FILE"
)"

echo "Waiting for the Sonarr API..."

until curl -fsS \
    -H "X-Api-Key: $API_KEY" \
    "$SONARR_URL/api/v3/system/status" >/dev/null; do
    sleep 1
done

CURRENT_CONFIG="$(mktemp)"
UPDATED_CONFIG="$(mktemp)"
trap 'rm -f "$CURRENT_CONFIG" "$UPDATED_CONFIG"' EXIT

curl -fsS \
    -H "X-Api-Key: $API_KEY" \
    "$SONARR_URL/api/v3/config/host" \
    > "$CURRENT_CONFIG"

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
    "$CURRENT_CONFIG" > "$UPDATED_CONFIG"

curl -fsS \
    -X PUT \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "@$UPDATED_CONFIG" \
    "$SONARR_URL/api/v3/config/host"

ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/data/media/tv}"

echo "Checking Sonarr root folder..."

ROOT_FOLDERS="$(
    curl -fsS \
        -H "X-Api-Key: $API_KEY" \
        "$SONARR_URL/api/v3/rootfolder"
)"

if jq -e \
    --arg path "$ROOT_FOLDER" \
    'any(.[]; (.path | rtrimstr("/")) == ($path | rtrimstr("/")))' \
    <<< "$ROOT_FOLDERS" >/dev/null; then

    echo "Root folder already configured: $ROOT_FOLDER"
else
    echo "Creating root folder: $ROOT_FOLDER"

    curl -fsS \
        -X POST \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        --data "$(jq -n --arg path "$ROOT_FOLDER" '{path: $path}')" \
        "$SONARR_URL/api/v3/rootfolder" >/dev/null

    echo "Root folder created."
fi

echo
echo "Sonarr authentication configured."
