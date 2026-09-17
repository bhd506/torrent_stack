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

for command_name in curl docker jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name" >&2
        exit 1
    fi
done

QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-}"

QBITTORRENT_SERVICE="${QBITTORRENT_SERVICE:-qbittorrent}"
QBITTORRENT_URL="${QBITTORRENT_URL:-http://127.0.0.1:${WEBUI_PORT:-8080}}"
QBITTORRENT_URL="${QBITTORRENT_URL%/}"

QBITTORRENT_SAVE_PATH="${QBITTORRENT_SAVE_PATH:-/data/downloads}"
QBITTORRENT_TEMP_PATH="${QBITTORRENT_TEMP_PATH:-/data/downloads/incomplete}"
QBITTORRENT_SONARR_CATEGORY="${QBITTORRENT_SONARR_CATEGORY:-sonarr}"
QBITTORRENT_SONARR_CATEGORY_PATH="${QBITTORRENT_SONARR_CATEGORY_PATH:-/data/downloads/tv}"
QBITTORRENT_RADARR_CATEGORY="${QBITTORRENT_RADARR_CATEGORY:-radarr}"
QBITTORRENT_RADARR_CATEGORY_PATH="${QBITTORRENT_RADARR_CATEGORY_PATH:-/data/downloads/movies}"
QBITTORRENT_TORRENT_PORT="${QBITTORRENT_TORRENT_PORT:-${TORRENTING_PORT:-6881}}"
PIA_VPN_PORT_FORWARDING="${PIA_VPN_PORT_FORWARDING:-on}"
QBITTORRENT_WAIT_SECONDS="${QBITTORRENT_WAIT_SECONDS:-${STACK_SERVICE_WAIT_SECONDS:-120}}"
QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS="${QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS:-60}"

if [[ -z "$QBITTORRENT_USERNAME" || -z "$QBITTORRENT_PASSWORD" ]]; then
    echo "Error: QBITTORRENT_USERNAME and QBITTORRENT_PASSWORD must be set in $ENV_FILE" >&2
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

if [[ ! "$QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Error: QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS must be numeric" >&2
    exit 1
fi

for path in \
    "$QBITTORRENT_SAVE_PATH" \
    "$QBITTORRENT_TEMP_PATH" \
    "$QBITTORRENT_SONARR_CATEGORY_PATH" \
    "$QBITTORRENT_RADARR_CATEGORY_PATH"; do

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

LAST_LOGIN_STATUS=""
LAST_LOGIN_BODY=""

login() {
    local login_username="$1"
    local login_password="$2"
    local http_status verify_status

    : >"$COOKIE_JAR"
    : >"$BODY_FILE"

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

    LAST_LOGIN_STATUS="$http_status"
    LAST_LOGIN_BODY="$(cat "$BODY_FILE" 2>/dev/null || true)"

    if [[ "$http_status" == "403" ]] && grep -qi 'banned' "$BODY_FILE" 2>/dev/null; then
        return 2
    fi

    # qBittorrent has used both 200/Ok. and 204/empty as successful login
    # responses. Do not depend on response text or a particular cookie name.
    if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        return 1
    fi

    verify_status="$(
        curl \
            -sS \
            --connect-timeout 5 \
            --max-time 15 \
            -o "$BODY_FILE" \
            -w '%{http_code}' \
            -b "$COOKIE_JAR" \
            -H "Referer: $QBITTORRENT_URL/" \
            "$QBITTORRENT_URL/api/v2/app/preferences" \
            2>/dev/null \
            || true
    )"

    if [[ "$verify_status" != "200" ]]; then
        LAST_LOGIN_STATUS="$verify_status"
        LAST_LOGIN_BODY="$(cat "$BODY_FILE" 2>/dev/null || true)"
        return 1
    fi

    # A valid authenticated preferences response is JSON. This proves the
    # session works without assuming SID vs QBT_SID_<port> naming.
    jq -e 'type == "object"' "$BODY_FILE" >/dev/null 2>&1
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

wait_for_http_reachable \
    "$QBITTORRENT_SERVICE" \
    "qBittorrent" \
    "$QBITTORRENT_URL/" \
    "$QBITTORRENT_WAIT_SECONDS"

authenticated=false

# Normal path after permanent credentials have been configured.
if login "$QBITTORRENT_USERNAME" "$QBITTORRENT_PASSWORD"; then
    authenticated=true
    echo "Authenticated using permanent credentials."
else
    login_rc=$?
    if (( login_rc == 2 )); then
        echo "Error: qBittorrent rejected authentication because this client IP is banned after previous failed attempts." >&2
        echo "       Stop retrying clients, restart qBittorrent to clear the temporary ban, then run setup again." >&2
        print_service_diagnostics "$QBITTORRENT_SERVICE" "qBittorrent"
        exit 1
    fi
fi

# Fresh-install path using the temporary password from the logs.
# LinuxServer documents that qBittorrent prints this password during startup,
# but the WebUI can become reachable slightly before that line appears. Poll
# instead of reading the log once, and only retry when a new password appears.
if [[ "$authenticated" != true ]]; then
    echo "Waiting for qBittorrent's temporary first-run password..."

    last_temp_password=""
    temp_password_seen=false

    for ((second = 1; second <= QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS; second++)); do
        TEMP_PASSWORD="$(
            docker compose logs \
                --no-color \
                "$QBITTORRENT_SERVICE" \
                2>&1 |
            grep -iE 'temporary password is provided for this session:' |
            sed -nE \
                's/.*[Tt]emporary password is provided for this session:[[:space:]]*([^[:space:]]+).*/\1/p' |
            tail -n 1 |
            tr -d '\r' \
            || true
        )"

        if [[ -n "$TEMP_PASSWORD" ]]; then
            temp_password_seen=true

            # A restarted container can still have an older temporary password
            # in its current log. Do not hammer qBittorrent with the same stale
            # credential while waiting for the newest startup line to appear.
            if [[ "$TEMP_PASSWORD" != "$last_temp_password" ]]; then
                last_temp_password="$TEMP_PASSWORD"

                if login "admin" "$TEMP_PASSWORD"; then
                    authenticated=true
                    echo "Authenticated using temporary first-run credentials."
                    break
                else
                    login_rc=$?
                    if (( login_rc == 2 )); then
                        echo "Error: qBittorrent banned this client IP during bootstrap authentication." >&2
                        echo "       Restart qBittorrent after stopping retrying clients, then run setup again." >&2
                        print_service_diagnostics "$QBITTORRENT_SERVICE" "qBittorrent"
                        exit 1
                    fi
                fi
            fi
        fi

        sleep 1
    done

    if [[ "$authenticated" != true ]]; then
        if [[ "$temp_password_seen" == true ]]; then
            echo "Error: qBittorrent temporary credentials were found but not accepted" >&2
        else
            echo "Error: permanent qBittorrent credentials were rejected and no temporary first-run password appeared in the container log within ${QBITTORRENT_TEMP_PASSWORD_WAIT_SECONDS}s" >&2
            echo "       This usually means the qBittorrent config already contains different permanent WebUI credentials." >&2
        fi
        exit 1
    fi
fi

if [[ "$authenticated" != true ]]; then
    echo "Error: qBittorrent authentication failed" >&2
    exit 1
fi

echo "Ensuring download directories exist..."

mkdir -p "$(host_path_for "$QBITTORRENT_SAVE_PATH")"
mkdir -p "$(host_path_for "$QBITTORRENT_TEMP_PATH")"
mkdir -p "$(host_path_for "$QBITTORRENT_SONARR_CATEGORY_PATH")"
mkdir -p "$(host_path_for "$QBITTORRENT_RADARR_CATEGORY_PATH")"

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

            # Category save paths only become deterministic when new torrents
            # use Automatic Torrent Management. These relocation options keep
            # category/path changes consistent for existing automatic torrents.
            auto_tmm_enabled: true,
            torrent_changed_tmm_enabled: true,
            save_path_changed_tmm_enabled: true,
            category_changed_tmm_enabled: true,

            # qBittorrent 5.x can also resolve category paths in Manual mode.
            # Keeping this enabled makes category routing resilient even if a
            # torrent is manually switched out of Automatic mode later.
            use_category_paths_in_manual_mode: true,

            listen_port: $listen_port,
            web_ui_csrf_protection_enabled: true,
            web_ui_clickjacking_protection_enabled: true,
            web_ui_host_header_validation_enabled: true,
            # Gluetun runs in the same network namespace as qBittorrent and
            # uses localhost to synchronize PIA dynamic forwarded port.
            # This bypass only applies to localhost, not Sonarr/Radarr or LAN clients.
            bypass_local_auth: true,
            bypass_auth_subnet_whitelist_enabled: false
        }'
)"

echo "Applying download, Automatic Torrent Management, port, and security settings..."

api_post_json \
    "/api/v2/app/setPreferences" \
    "$PREFERENCES"

CATEGORIES="$(
    api_get "/api/v2/torrents/categories"
)"

ensure_category() {
    local category="$1"
    local category_path="$2"
    local current_path

    if jq -e --arg category "$category" 'has($category)' <<<"$CATEGORIES" >/dev/null; then
        current_path="$(
            jq -r --arg category "$category" '.[$category].savePath // empty' <<<"$CATEGORIES"
        )"

        if [[ "${current_path%/}" != "${category_path%/}" ]]; then
            echo "Updating category: $category"
            api_post_form \
                "/api/v2/torrents/editCategory" \
                "category=$category" \
                "savePath=$category_path"
        else
            echo "Category already configured: $category"
        fi
    else
        echo "Creating category: $category"
        api_post_form \
            "/api/v2/torrents/createCategory" \
            "category=$category" \
            "savePath=$category_path"
    fi

    CATEGORIES="$(api_get "/api/v2/torrents/categories")"
}

ensure_category "$QBITTORRENT_SONARR_CATEGORY" "$QBITTORRENT_SONARR_CATEGORY_PATH"
ensure_category "$QBITTORRENT_RADARR_CATEGORY" "$QBITTORRENT_RADARR_CATEGORY_PATH"

enable_automatic_management_for_category() {
    local category="$1"
    local torrents hashes

    torrents="$(
        curl \
            -fsS \
            --connect-timeout 5 \
            --max-time 30 \
            -b "$COOKIE_JAR" \
            -H "Referer: $QBITTORRENT_URL/" \
            --get \
            --data-urlencode "category=$category" \
            "$QBITTORRENT_URL/api/v2/torrents/info"
    )"

    hashes="$(jq -r '[.[].hash] | join("|")' <<<"$torrents")"

    if [[ -n "$hashes" ]]; then
        echo "Enabling Automatic Torrent Management for existing '$category' torrents..."
        api_post_form \
            "/api/v2/torrents/setAutoManagement" \
            "hashes=$hashes" \
            "enable=true"
    fi
}

# New torrents inherit auto_tmm_enabled. Re-running this script also fixes
# already-existing Sonarr/Radarr torrents so their category save paths apply.
enable_automatic_management_for_category "$QBITTORRENT_SONARR_CATEGORY"
enable_automatic_management_for_category "$QBITTORRENT_RADARR_CATEGORY"

CREDENTIALS="$(
    jq \
        -n \
        --arg username "$QBITTORRENT_USERNAME" \
        --arg password "$QBITTORRENT_PASSWORD" \
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

for ((attempt = 1; attempt <= 2; attempt++)); do
    if login "$QBITTORRENT_USERNAME" "$QBITTORRENT_PASSWORD"; then
        verified=true
        break
    fi

    sleep 2
done

if [[ "$verified" != true ]]; then
    echo "Error: permanent credential verification failed; setup stopped before repeated attempts can trigger a qBittorrent IP ban" >&2
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
    --arg pia_port_forwarding "$PIA_VPN_PORT_FORWARDING" \
    '
        def trimslash:
            sub("/+$"; "");

        (.save_path | trimslash) == ($save_path | trimslash)
        and .temp_path_enabled == true
        and (.temp_path | trimslash) == ($temp_path | trimslash)
        and .auto_tmm_enabled == true
        and .torrent_changed_tmm_enabled == true
        and .save_path_changed_tmm_enabled == true
        and .category_changed_tmm_enabled == true
        and .use_category_paths_in_manual_mode == true
        and (($pia_port_forwarding == "on") or (.listen_port == $listen_port))
        and .bypass_local_auth == true
    ' \
    <<<"$CURRENT_PREFERENCES" \
    >/dev/null; then

    echo "Error: qBittorrent preference verification failed" >&2
    exit 1
fi

verify_category() {
    local category="$1"
    local save_path="$2"

    jq \
        -e \
        --arg category "$category" \
        --arg save_path "$save_path" \
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
        >/dev/null
}

if ! verify_category "$QBITTORRENT_SONARR_CATEGORY" "$QBITTORRENT_SONARR_CATEGORY_PATH"; then
    echo "Error: qBittorrent Sonarr category verification failed" >&2
    exit 1
fi

if ! verify_category "$QBITTORRENT_RADARR_CATEGORY" "$QBITTORRENT_RADARR_CATEGORY_PATH"; then
    echo "Error: qBittorrent Radarr category verification failed" >&2
    exit 1
fi

echo
echo "qBittorrent configuration completed successfully."
echo "  WebUI:         $QBITTORRENT_URL"
echo "  Username:      $QBITTORRENT_USERNAME"
echo "  Download path: $QBITTORRENT_SAVE_PATH"
echo "  Incomplete:    $QBITTORRENT_TEMP_PATH"
echo "  Sonarr:        $QBITTORRENT_SONARR_CATEGORY -> $QBITTORRENT_SONARR_CATEGORY_PATH (Automatic)"
echo "  Radarr:        $QBITTORRENT_RADARR_CATEGORY -> $QBITTORRENT_RADARR_CATEGORY_PATH (Automatic)"
echo "  Torrent port:  $QBITTORRENT_TORRENT_PORT"
