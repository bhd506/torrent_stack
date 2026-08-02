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

PROWLARR_CONFIG_FILE="${PROWLARR_CONFIG_FILE:-$PROJECT_ROOT/config/prowlarr/config.xml}"
PROWLARR_WAIT_SECONDS="${PROWLARR_WAIT_SECONDS:-120}"
INDEXER_PRIORITY="${INDEXER_PRIORITY:-25}"

if [[ ! -f "$PROWLARR_CONFIG_FILE" ]]; then
    echo "Error: Prowlarr config file not found: $PROWLARR_CONFIG_FILE" >&2
    exit 1
fi

if [[ ! "$PROWLARR_WAIT_SECONDS" =~ ^[0-9]+$ ]] ||
   (( PROWLARR_WAIT_SECONDS < 1 )); then

    echo "Error: PROWLARR_WAIT_SECONDS must be a positive integer" >&2
    exit 1
fi

if [[ ! "$INDEXER_PRIORITY" =~ ^[0-9]+$ ]] ||
   (( INDEXER_PRIORITY < 1 || INDEXER_PRIORITY > 50 )); then

    echo "Error: INDEXER_PRIORITY must be between 1 and 50" >&2
    exit 1
fi

API_KEY="$(
    sed -n \
        's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' \
        "$PROWLARR_CONFIG_FILE" |
    head -n 1
)"

if [[ -z "$API_KEY" ]]; then
    echo "Error: Prowlarr API key not found in $PROWLARR_CONFIG_FILE" >&2
    exit 1
fi

prowlarr_get() {
    local endpoint="$1"

    curl \
        --fail-with-body \
        -sS \
        --connect-timeout 5 \
        --max-time 60 \
        -H "X-Api-Key: $API_KEY" \
        "$PROWLARR_URL$endpoint"
}

prowlarr_send() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"

    curl \
        --fail-with-body \
        -sS \
        --connect-timeout 5 \
        --max-time 120 \
        -X "$method" \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$PROWLARR_URL$endpoint"
}

cd "$PROJECT_ROOT"

echo "Waiting for Prowlarr..."

ready=false

for ((second = 1; second <= PROWLARR_WAIT_SECONDS; second++)); do
    if prowlarr_get "/api/v1/system/status" >/dev/null 2>&1; then
        ready=true
        break
    fi

    sleep 1
done

if [[ "$ready" != true ]]; then
    echo "Error: Prowlarr did not become ready" >&2
    exit 1
fi

echo "Reading the Standard application profile..."

APP_PROFILES="$(
    prowlarr_get "/api/v1/appprofile"
)"

APP_PROFILE_ID="$(
    jq -r '
        (
            [
                .[]
                | select(
                    (.name // "" | ascii_downcase) == "standard"
                )
            ][0].id
        )
        // (.[0].id)
        // empty
    ' <<<"$APP_PROFILES"
)"

if [[ -z "$APP_PROFILE_ID" || "$APP_PROFILE_ID" == "null" ]]; then
    echo "Error: no Prowlarr application profile was found" >&2
    exit 1
fi

echo "Reading Prowlarr indexer definitions..."

SCHEMAS="$(
    prowlarr_get "/api/v1/indexer/schema"
)"

configure_indexer() {
    local definition_name="$1"
    local display_name="$2"
    local current_indexers
    local existing
    local payload
    local indexer_id
    local method
    local endpoint

    current_indexers="$(
        prowlarr_get "/api/v1/indexer"
    )"

    existing="$(
        jq \
            --arg definition "$definition_name" \
            --arg display "$display_name" \
            '
                def normalized:
                    ascii_downcase
                    | gsub("[^a-z0-9]"; "");

                [
                    .[]
                    | select(
                        (
                            (.definitionName // "")
                            | normalized
                        ) == (
                            $definition
                            | normalized
                        )
                        or (
                            (
                                (.definitionName // "")
                                | normalized
                            ) == ""
                            and (
                                (.name // "")
                                | normalized
                            ) == (
                                $display
                                | normalized
                            )
                        )
                    )
                ][0] // empty
            ' \
            <<<"$current_indexers"
    )"

    if [[ -n "$existing" ]]; then
        payload="$existing"
        indexer_id="$(jq -r '.id' <<<"$existing")"
        method="PUT"
        endpoint="/api/v1/indexer/$indexer_id"

        echo "Updating indexer: $display_name"
    else
        payload="$(
            jq \
                --arg definition "$definition_name" \
                --arg display "$display_name" \
                '
                    def normalized:
                        ascii_downcase
                        | gsub("[^a-z0-9]"; "");

                    [
                        .[]
                        | select(
                            (
                                (.definitionName // "")
                                | normalized
                            ) == (
                                $definition
                                | normalized
                            )
                            or (
                                (.name // "")
                                | normalized
                            ) == (
                                $display
                                | normalized
                            )
                            or (
                                (.implementationName // "")
                                | normalized
                            ) == (
                                $display
                                | normalized
                            )
                        )
                    ][0] // empty
                ' \
                <<<"$SCHEMAS"
        )"

        method="POST"
        endpoint="/api/v1/indexer"

        echo "Creating indexer: $display_name"
    fi

    if [[ -z "$payload" ]]; then
        echo "Error: Prowlarr definition not found for $display_name" >&2
        echo "Definition name: $definition_name" >&2
        exit 1
    fi

    payload="$(
        jq \
            --arg name "$display_name" \
            --argjson profile_id "$APP_PROFILE_ID" \
            --argjson priority "$INDEXER_PRIORITY" \
            '
                .name = $name
                | .enable = true
                | .redirect = false
                | .appProfileId = $profile_id
                | .priority = $priority
            ' \
            <<<"$payload"
    )"

    echo "Testing indexer: $display_name"

    prowlarr_send \
        POST \
        "/api/v1/indexer/test" \
        "$payload" \
        >/dev/null

    echo "Saving indexer: $display_name"

    prowlarr_send \
        "$method" \
        "$endpoint" \
        "$payload" \
        >/dev/null
}

configure_indexer \
    "limetorrents" \
    "LimeTorrents"

configure_indexer \
    "thepiratebay" \
    "The Pirate Bay"

echo "Verifying saved indexers..."

SAVED="$(
    prowlarr_get "/api/v1/indexer"
)"

for definition_name in limetorrents thepiratebay; do
    if ! jq \
        -e \
        --arg definition "$definition_name" \
        --argjson profile_id "$APP_PROFILE_ID" \
        --argjson priority "$INDEXER_PRIORITY" \
        '
            def normalized:
                ascii_downcase
                | gsub("[^a-z0-9]"; "");

            any(
                .[];
                (
                    (.definitionName // "")
                    | normalized
                ) == (
                    $definition
                    | normalized
                )
                and .enable == true
                and .appProfileId == $profile_id
                and .priority == $priority
            )
        ' \
        <<<"$SAVED" \
        >/dev/null; then

        echo "Error: indexer verification failed: $definition_name" >&2
        exit 1
    fi
done

echo
echo "Prowlarr indexers configured successfully."
echo "  LimeTorrents:   enabled, priority $INDEXER_PRIORITY"
echo "  The Pirate Bay: enabled, priority $INDEXER_PRIORITY"
echo "  App profile ID: $APP_PROFILE_ID"
