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

for command_name in curl jq sed; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Error: required command not found: $command_name" >&2
        exit 1
    }
done

SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"
RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
QBITTORRENT_URL="${QBITTORRENT_URL:-http://127.0.0.1:${WEBUI_PORT:-8080}}"
FILE_SECURITY_HOST_URL="${FILE_SECURITY_HOST_URL:-http://127.0.0.1:${FILE_SECURITY_HOST_PORT:-8081}}"

SONARR_CONFIG_FILE="${SONARR_CONFIG_FILE:-$PROJECT_ROOT/config/sonarr/config.xml}"
RADARR_CONFIG_FILE="${RADARR_CONFIG_FILE:-$PROJECT_ROOT/config/radarr/config.xml}"
PROWLARR_CONFIG_FILE="${PROWLARR_CONFIG_FILE:-$PROJECT_ROOT/config/prowlarr/config.xml}"

SONARR_ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/data/media/tv}"
RADARR_ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/data/media/movies}"
QBITTORRENT_SONARR_CATEGORY="${QBITTORRENT_SONARR_CATEGORY:-sonarr}"
QBITTORRENT_SONARR_CATEGORY_PATH="${QBITTORRENT_SONARR_CATEGORY_PATH:-/data/downloads/tv}"
QBITTORRENT_RADARR_CATEGORY="${QBITTORRENT_RADARR_CATEGORY:-radarr}"
QBITTORRENT_RADARR_CATEGORY_PATH="${QBITTORRENT_RADARR_CATEGORY_PATH:-/data/downloads/movies}"

SONARR_API_KEY="$(extract_api_key "$SONARR_CONFIG_FILE")"
RADARR_API_KEY="$(extract_api_key "$RADARR_CONFIG_FILE")"
PROWLARR_API_KEY="$(extract_api_key "$PROWLARR_CONFIG_FILE")"

[[ -n "$SONARR_API_KEY" ]] || { echo "Error: Sonarr API key missing" >&2; exit 1; }
[[ -n "$RADARR_API_KEY" ]] || { echo "Error: Radarr API key missing" >&2; exit 1; }
[[ -n "$PROWLARR_API_KEY" ]] || { echo "Error: Prowlarr API key missing" >&2; exit 1; }

arr_get() {
    local url="$1" key="$2" endpoint="$3"
    curl -fsS --connect-timeout 5 --max-time 30 -H "X-Api-Key: $key" "${url%/}$endpoint"
}

echo "Verifying FileSecurityManager health..."
curl -fsS --connect-timeout 5 --max-time 15 "${FILE_SECURITY_HOST_URL%/}/api/v1/health" >/dev/null

echo "Verifying Sonarr settings..."
arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/system/status" >/dev/null
SONARR_DC_CONFIG="$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/config/downloadclient")"
SONARR_MEDIA_CONFIG="$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/config/mediamanagement")"
SONARR_ROOTS="$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/rootfolder")"
SONARR_CLIENTS="$(arr_get "$SONARR_URL" "$SONARR_API_KEY" "/api/v3/downloadclient")"

jq -e '.enableCompletedDownloadHandling == false' <<<"$SONARR_DC_CONFIG" >/dev/null || {
    echo "Error: Sonarr completed download handling is not disabled" >&2; exit 1;
}
jq -e '.copyUsingHardlinks == true' <<<"$SONARR_MEDIA_CONFIG" >/dev/null || {
    echo "Error: Sonarr hardlinks are not enabled" >&2; exit 1;
}
jq -e --arg path "$SONARR_ROOT_FOLDER" \
    'any(.[]; (.path | rtrimstr("/")) == ($path | rtrimstr("/")))' \
    <<<"$SONARR_ROOTS" >/dev/null || {
    echo "Error: Sonarr root folder is missing: $SONARR_ROOT_FOLDER" >&2; exit 1;
}
jq -e --arg category "$QBITTORRENT_SONARR_CATEGORY" '
    def field($name): [.fields[] | select(.name == $name) | .value][0];
    any(.[]; .implementation == "QBittorrent" and field("tvCategory") == $category)
' <<<"$SONARR_CLIENTS" >/dev/null || {
    echo "Error: Sonarr qBittorrent download client/category did not verify" >&2; exit 1;
}

echo "Verifying Radarr settings..."
arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/system/status" >/dev/null
RADARR_DC_CONFIG="$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/config/downloadclient")"
RADARR_MEDIA_CONFIG="$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/config/mediamanagement")"
RADARR_ROOTS="$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/rootfolder")"
RADARR_CLIENTS="$(arr_get "$RADARR_URL" "$RADARR_API_KEY" "/api/v3/downloadclient")"

jq -e '.enableCompletedDownloadHandling == false' <<<"$RADARR_DC_CONFIG" >/dev/null || {
    echo "Error: Radarr completed download handling is not disabled" >&2; exit 1;
}
jq -e '.copyUsingHardlinks == true' <<<"$RADARR_MEDIA_CONFIG" >/dev/null || {
    echo "Error: Radarr hardlinks are not enabled" >&2; exit 1;
}
jq -e --arg path "$RADARR_ROOT_FOLDER" \
    'any(.[]; (.path | rtrimstr("/")) == ($path | rtrimstr("/")))' \
    <<<"$RADARR_ROOTS" >/dev/null || {
    echo "Error: Radarr root folder is missing: $RADARR_ROOT_FOLDER" >&2; exit 1;
}
jq -e --arg category "$QBITTORRENT_RADARR_CATEGORY" '
    def field($name): [.fields[] | select(.name == $name) | .value][0];
    any(.[]; .implementation == "QBittorrent" and field("movieCategory") == $category)
' <<<"$RADARR_CLIENTS" >/dev/null || {
    echo "Error: Radarr qBittorrent download client/category did not verify" >&2; exit 1;
}

echo "Verifying Prowlarr application links..."
arr_get "$PROWLARR_URL" "$PROWLARR_API_KEY" "/api/v1/system/status" >/dev/null
PROWLARR_APPS="$(arr_get "$PROWLARR_URL" "$PROWLARR_API_KEY" "/api/v1/applications")"
jq -e 'any(.[]; .implementation == "Sonarr" and .syncLevel == "fullSync")' <<<"$PROWLARR_APPS" >/dev/null || {
    echo "Error: Prowlarr -> Sonarr full-sync application is missing" >&2; exit 1;
}
jq -e 'any(.[]; .implementation == "Radarr" and .syncLevel == "fullSync")' <<<"$PROWLARR_APPS" >/dev/null || {
    echo "Error: Prowlarr -> Radarr full-sync application is missing" >&2; exit 1;
}

echo "Verifying qBittorrent authentication and routing..."
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
COOKIE_JAR="$WORK_DIR/cookies.txt"
BODY_FILE="$WORK_DIR/body.txt"
LOGIN_STATUS="$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$BODY_FILE" -w '%{http_code}' -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "Referer: ${QBITTORRENT_URL%/}/" \
    --data-urlencode "username=$QBITTORRENT_USERNAME" \
    --data-urlencode "password=$QBITTORRENT_PASSWORD" \
    "${QBITTORRENT_URL%/}/api/v2/auth/login" 2>/dev/null || true)"
if [[ ! "$LOGIN_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    echo "Error: qBittorrent login failed during final verification (HTTP $LOGIN_STATUS)" >&2
    cat "$BODY_FILE" >&2 || true
    exit 1
fi

PREF_STATUS="$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$BODY_FILE" -w '%{http_code}' -b "$COOKIE_JAR" \
    -H "Referer: ${QBITTORRENT_URL%/}/" \
    "${QBITTORRENT_URL%/}/api/v2/app/preferences" 2>/dev/null || true)"
if [[ "$PREF_STATUS" != "200" ]] || ! jq -e 'type == "object"' "$BODY_FILE" >/dev/null 2>&1; then
    echo "Error: qBittorrent authenticated session verification failed (HTTP $PREF_STATUS)" >&2
    cat "$BODY_FILE" >&2 || true
    exit 1
fi
QBIT_PREFS="$(cat "$BODY_FILE")"
QBIT_CATEGORIES="$(curl -fsS --connect-timeout 5 --max-time 15 -b "$COOKIE_JAR" \
    -H "Referer: ${QBITTORRENT_URL%/}/" \
    "${QBITTORRENT_URL%/}/api/v2/torrents/categories")"

jq -e '.auto_tmm_enabled == true and .category_changed_tmm_enabled == true and .save_path_changed_tmm_enabled == true' \
    <<<"$QBIT_PREFS" >/dev/null || {
    echo "Error: qBittorrent Automatic Torrent Management settings did not verify" >&2; exit 1;
}
jq -e --arg category "$QBITTORRENT_SONARR_CATEGORY" --arg path "$QBITTORRENT_SONARR_CATEGORY_PATH" '
    def trimslash: sub("/+$"; "");
    has($category) and ((.[$category].savePath | trimslash) == ($path | trimslash))
' <<<"$QBIT_CATEGORIES" >/dev/null || {
    echo "Error: qBittorrent Sonarr category path did not verify" >&2; exit 1;
}
jq -e --arg category "$QBITTORRENT_RADARR_CATEGORY" --arg path "$QBITTORRENT_RADARR_CATEGORY_PATH" '
    def trimslash: sub("/+$"; "");
    has($category) and ((.[$category].savePath | trimslash) == ($path | trimslash))
' <<<"$QBIT_CATEGORIES" >/dev/null || {
    echo "Error: qBittorrent Radarr category path did not verify" >&2; exit 1;
}

echo "Final stack verification passed."
