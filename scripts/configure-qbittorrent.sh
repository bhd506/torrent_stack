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

QBITTORRENT_SERVICE="${QBITTORRENT_SERVICE:-qbittorrent}"
QBITTORRENT_URL="${QBITTORRENT_URL:-http://127.0.0.1:${WEBUI_PORT:-8080}}"
QBITTORRENT_URL="${QBITTORRENT_URL%/}"

QBITTORRENT_SAVE_PATH="${QBITTORRENT_SAVE_PATH:-/data/downloads}"
QBITTORRENT_TEMP_PATH="${QBITTORRENT_TEMP_PATH:-/data/downloads/incomplete}"
QBITTORRENT_CATEGORY="${QBITTORRENT_CATEGORY:-sonarr}"
QBITTORRENT_CATEGORY_PATH="${QBITTORRENT_CATEGORY_PATH:-/data/downloads/tv}"
QBITTORRENT_TORRENT_PORT="${QBITTORRENT_TORRENT_PORT:-${TORRENTING_PORT:-6881}}"
QBITTORRENT_WAIT_SECONDS="${QBITTORRENT_WAIT_SECONDS:-120}"

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "Error: USERNAME and PASSWORD must be set in $ENV_FILE" >&2
    exit 1
fi

if [[ ! "$QBITTORRENT_TORRENT_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: QBITTORRENT_TORRENT_PORT must be numeric" >&2
    exit 1
fi

if (( QBITTORRENT_TORRENT_PORT < 1 || QBITTORRENT_TORRENT_PORT > 65535 )); then
    echo "Error: QBITTORRENT_TORRENT_PORT must be between 1 and 65535" >&2
    exit 1
fi

if [[ ! "$QBITTORRENT_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Error: QBITTORRENT_WAIT_SECONDS must be numeric" >&2
    exit 1
fi

for path in \
    "$QBITTORRENT_SAVE_PATH" \
    "$QBITTORRENT_TEMP_PATH" \
    "$QBITTORRENT_CATEGORY_PATH"; do

    if [[ "$path" != "/data" && "$path" != /data/* ]]; then
        echo "Error: qBittorrent paths must be inside /data: $path" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d)"
COOKIE_JAR="$WORK_DIR/cookies.txt"
BODY_FILE="$WORK_DIR/body.txt"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

has_session_cookie() {
    awk -F '\t' '
        NF >= 7 && $6 ~ /SID/ {
            found = 1
        }

        END {
            exit(found ? 0 : 1)
        }
    ' "$COOKIE_JAR"
}

login() {
    local login_username="$1"
    local login_password="$2"
    local http_status

    : >"$COOKIE_JAR"

    http_status="$(
        curl \
            -sS \
            --connect-timeout 5 \
            --max-time 15 \
            -o "$BODY_FILE" \
            -w '%{http_code}' \
            -c "$COOKIE_JAR" \
            -b "$COOKIE_JAR" \
            -H "Referer: $QBITTORRENT_URL/" \
            --data-urlencode "username=$login_username" \
            --data-urlencode "password=$login_password" \
            "$QBITTORRENT_URL/api/v2/auth/login" \
            2>/dev/null \
            || true
    )"

    if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        return 1
    fi

    has_session_cookie
}

api_get() {
    local endpoint="$1"

    curl \
        -fsS \
        --connect-timeout 5 \
        --max-time 30 \
        -b "$COOKIE_JAR" \
        -H "Referer: $QBITTORRENT_URL/" \
        "$QBITTORRENT_URL$endpoint"
}

api_post_json() {
    local endpoint="$1"
    local payload="$2"
    local http_status

    http_status="$(
        curl \
            -sS \
            --connect-timeout 5 \
            --max-time 30 \
            -o "$BODY_FILE" \
            -w '%{http_code}' \
            -b "$COOKIE_JAR" \
            -H "Referer: $QBITTORRENT_URL/" \
            --data-urlencode "json=$payload" \
            "$QBITTORRENT_URL$endpoint"
    )"

    if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        echo "Error: qBittorrent API request failed: $endpoint (HTTP $http_status)" >&2
        cat "$BODY_FILE" >&2
        exit 1
    fi
}

api_post_form() {
    local endpoint="$1"
    shift

    local http_status
    local arguments=()
    local item

    for item in "$@"; do
        arguments+=(--data-urlencode "$item")
    done

    http_status="$(
        curl \
            -sS \
            --connect-timeout 5 \
            --max-time 30 \
            -o "$BODY_FILE" \
            -w '%{http_code}' \
            -b "$COOKIE_JAR" \
            -H "Referer: $QBITTORRENT_URL/" \
            "${arguments[@]}" \
            "$QBITTORRENT_URL$endpoint"
    )"

    if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        echo "Error: qBittorrent API request failed: $endpoint (HTTP $http_status)" >&2
        cat "$BODY_FILE" >&2
        exit 1
    fi
}

host_path_for() {
    local container_path="$1"

    if [[ "$container_path" == "/data" ]]; then
        printf '%s/data\n' "$PROJECT_ROOT"
    else
        printf '%s/data/%s\n' \
            "$PROJECT_ROOT" \
            "${container_path#/data/}"
    fi
}

cd "$PROJECT_ROOT"

echo "Starting qBittorrent..."

docker compose up -d "$QBITTORRENT_SERVICE"

echo "Waiting for the qBittorrent WebUI at $QBITTORRENT_URL..."

ready=false

for ((second = 1; second <= QBITTORRENT_WAIT_SECONDS; second++)); do
    if curl \
        -sS \
        --connect-timeout 2 \
        --max-time 3 \
        -o /dev/null \
        "$QBITTORRENT_URL/" \
        2>/dev/null; then

        ready=true
        break
    fi

    sleep 1
done

if [[ "$ready" != true ]]; then
    echo "Error: qBittorrent did not become reachable" >&2
    exit 1
fi

authenticated=false

# Normal path after permanent credentials have been configured.
if login "$USERNAME" "$PASSWORD"; then
    authenticated=true
    echo "Authenticated using permanent credentials."
fi

# Fresh-install path using the temporary password from the logs.
if [[ "$authenticated" != true ]]; then
    echo "Reading qBittorrent's temporary first-run password..."

    TEMP_PASSWORD="$(
        docker compose logs \
            --no-color \
            "$QBITTORRENT_SERVICE" \
            2>&1 |
        sed -nE \
            's/.*temporary password is provided for this session:[[:space:]]*([^[:space:]]+).*/\1/p' |
        tail -n 1 |
        tr -d '\r'
    )"

    if [[ -z "$TEMP_PASSWORD" ]]; then
        echo "Error: temporary password not found in qBittorrent logs" >&2
        exit 1
    fi

    if login "admin" "$TEMP_PASSWORD"; then
        authenticated=true
        echo "Authenticated using temporary first-run credentials."
    fi
fi

if [[ "$authenticated" != true ]]; then
    echo "Error: qBittorrent authentication failed" >&2
    exit 1
fi

echo "Ensuring download directories exist..."

mkdir -p "$(host_path_for "$QBITTORRENT_SAVE_PATH")"
mkdir -p "$(host_path_for "$QBITTORRENT_TEMP_PATH")"
mkdir -p "$(host_path_for "$QBITTORRENT_CATEGORY_PATH")"

PREFERENCES="$(
    jq \
        -n \
        --arg save_path "$QBITTORRENT_SAVE_PATH" \
        --arg temp_path "$QBITTORRENT_TEMP_PATH" \
        --argjson listen_port "$QBITTORRENT_TORRENT_PORT" \
        '{
            save_path: $save_path,
            temp_path_enabled: true,
            temp_path: $temp_path,
            listen_port: $listen_port,
            web_ui_csrf_protection_enabled: true,
            web_ui_clickjacking_protection_enabled: true,
            web_ui_host_header_validation_enabled: true,
            bypass_local_auth: false,
            bypass_auth_subnet_whitelist_enabled: false
        }'
)"

echo "Applying download, port, and security settings..."

api_post_json \
    "/api/v2/app/setPreferences" \
    "$PREFERENCES"

CATEGORIES="$(
    api_get "/api/v2/torrents/categories"
)"

if jq \
    -e \
    --arg category "$QBITTORRENT_CATEGORY" \
    'has($category)' \
    <<<"$CATEGORIES" \
    >/dev/null; then

    CURRENT_CATEGORY_PATH="$(
        jq \
            -r \
            --arg category "$QBITTORRENT_CATEGORY" \
            '.[$category].savePath // empty' \
            <<<"$CATEGORIES"
    )"

    if [[ "${CURRENT_CATEGORY_PATH%/}" != "${QBITTORRENT_CATEGORY_PATH%/}" ]]; then
        echo "Updating category: $QBITTORRENT_CATEGORY"

        api_post_form \
            "/api/v2/torrents/editCategory" \
            "category=$QBITTORRENT_CATEGORY" \
            "savePath=$QBITTORRENT_CATEGORY_PATH"
    else
        echo "Category already configured: $QBITTORRENT_CATEGORY"
    fi
else
    echo "Creating category: $QBITTORRENT_CATEGORY"

    api_post_form \
        "/api/v2/torrents/createCategory" \
        "category=$QBITTORRENT_CATEGORY" \
        "savePath=$QBITTORRENT_CATEGORY_PATH"
fi

CREDENTIALS="$(
    jq \
        -n \
        --arg username "$USERNAME" \
        --arg password "$PASSWORD" \
        '{
            web_ui_username: $username,
            web_ui_password: $password
        }'
)"

echo "Applying permanent credentials..."

api_post_json \
    "/api/v2/app/setPreferences" \
    "$CREDENTIALS"

echo "Verifying permanent credentials..."

verified=false

for ((attempt = 1; attempt <= 10; attempt++)); do
    if login "$USERNAME" "$PASSWORD"; then
        verified=true
        break
    fi

    sleep 1
done

if [[ "$verified" != true ]]; then
    echo "Error: permanent credential verification failed" >&2
    exit 1
fi

CURRENT_PREFERENCES="$(
    api_get "/api/v2/app/preferences"
)"

CURRENT_CATEGORIES="$(
    api_get "/api/v2/torrents/categories"
)"

if ! jq \
    -e \
    --arg save_path "$QBITTORRENT_SAVE_PATH" \
    --arg temp_path "$QBITTORRENT_TEMP_PATH" \
    --argjson listen_port "$QBITTORRENT_TORRENT_PORT" \
    '
        def trimslash:
            sub("/+$"; "");

        (.save_path | trimslash) == ($save_path | trimslash)
        and .temp_path_enabled == true
        and (.temp_path | trimslash) == ($temp_path | trimslash)
        and .listen_port == $listen_port
    ' \
    <<<"$CURRENT_PREFERENCES" \
    >/dev/null; then

    echo "Error: qBittorrent preference verification failed" >&2
    exit 1
fi

if ! jq \
    -e \
    --arg category "$QBITTORRENT_CATEGORY" \
    --arg save_path "$QBITTORRENT_CATEGORY_PATH" \
    '
        def trimslash:
            sub("/+$"; "");

        has($category)
        and (
            (.[$category].savePath | trimslash)
            ==
            ($save_path | trimslash)
        )
    ' \
    <<<"$CURRENT_CATEGORIES" \
    >/dev/null; then

    echo "Error: qBittorrent category verification failed" >&2
    exit 1
fi

echo
echo "qBittorrent configuration completed successfully."
echo "  WebUI:         $QBITTORRENT_URL"
echo "  Username:      $USERNAME"
echo "  Download path: $QBITTORRENT_SAVE_PATH"
echo "  Incomplete:    $QBITTORRENT_TEMP_PATH"
echo "  Category:      $QBITTORRENT_CATEGORY -> $QBITTORRENT_CATEGORY_PATH"
echo "  Torrent port:  $QBITTORRENT_TORRENT_PORT"
