#!/usr/bin/env bash
# Shared bootstrap/readiness helpers. Intended to be sourced by setup scripts.

service_container_id() {
    docker compose ps -q "$1" 2>/dev/null | head -n 1
}

service_state() {
    local service="$1"
    local cid
    cid="$(service_container_id "$service")"
    if [[ -z "$cid" ]]; then
        printf '%s\n' "missing"
        return 0
    fi
    docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || printf '%s\n' "unknown"
}

print_service_diagnostics() {
    local service="$1"
    local label="${2:-$service}"

    {
        echo
        echo "--- ${label} container state ---"
        docker compose ps "$service" || true
        echo "--- ${label} recent logs ---"
        docker compose logs --no-color --tail=100 "$service" || true
        echo "--- end ${label} diagnostics ---"
        echo
    } >&2
}

fail_if_service_terminal() {
    local service="$1"
    local label="${2:-$service}"
    local state
    state="$(service_state "$service")"

    case "$state" in
        exited|dead|restarting)
            echo "Error: ${label} container entered terminal state: ${state}" >&2
            print_service_diagnostics "$service" "$label"
            return 1
            ;;
    esac
    return 0
}

extract_api_key() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$file" | head -n 1
}

wait_for_arr_api() {
    local service="$1"
    local label="$2"
    local url="${3%/}"
    local config_file="$4"
    local status_endpoint="$5"
    local timeout="$6"
    local api_key=""

    echo "Waiting for ${label} configuration and API (timeout ${timeout}s)..." >&2

    for ((second = 1; second <= timeout; second++)); do
        fail_if_service_terminal "$service" "$label" || return 1

        api_key="$(extract_api_key "$config_file" 2>/dev/null || true)"
        if [[ -n "$api_key" ]] && curl \
            -fsS \
            --connect-timeout 2 \
            --max-time 5 \
            -H "X-Api-Key: $api_key" \
            "$url$status_endpoint" \
            >/dev/null 2>&1; then
            printf '%s\n' "$api_key"
            return 0
        fi

        sleep 1
    done

    echo "Error: ${label} did not become ready within ${timeout}s" >&2
    echo "Expected config: $config_file" >&2
    print_service_diagnostics "$service" "$label"
    return 1
}

wait_for_http_reachable() {
    local service="$1"
    local label="$2"
    local url="$3"
    local timeout="$4"
    local status

    echo "Waiting for ${label} HTTP service at ${url} (timeout ${timeout}s)..." >&2

    for ((second = 1; second <= timeout; second++)); do
        fail_if_service_terminal "$service" "$label" || return 1

        status="$(curl \
            -sS \
            --connect-timeout 2 \
            --max-time 4 \
            -o /dev/null \
            -w '%{http_code}' \
            "$url" 2>/dev/null || true)"

        if [[ "$status" =~ ^[234][0-9][0-9]$ ]]; then
            return 0
        fi
        sleep 1
    done

    echo "Error: ${label} HTTP service did not become reachable within ${timeout}s" >&2
    print_service_diagnostics "$service" "$label"
    return 1
}

wait_for_http_success() {
    local service="$1"
    local label="$2"
    local url="$3"
    local timeout="$4"

    echo "Waiting for ${label} health endpoint at ${url} (timeout ${timeout}s)..." >&2

    for ((second = 1; second <= timeout; second++)); do
        fail_if_service_terminal "$service" "$label" || return 1
        if curl \
            -fsS \
            --connect-timeout 2 \
            --max-time 5 \
            "$url" \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "Error: ${label} health endpoint did not become ready within ${timeout}s" >&2
    print_service_diagnostics "$service" "$label"
    return 1
}
