#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

if (( EUID == 0 )); then
    echo "Error: do not run kill.sh with sudo/root; use the same user that runs the stack." >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || {
    echo "Error: Docker is not installed or not on PATH." >&2
    exit 1
}
docker compose version >/dev/null 2>&1 || {
    echo "Error: Docker Compose plugin is not available." >&2
    exit 1
}

# Load COMPOSE_PROJECT_NAME if the user set one, without requiring the rest of
# the stack's secrets to be valid just to stop it.
if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

project_name="${COMPOSE_PROJECT_NAME:-}"
first_container="$(docker compose --profile runtime ps -aq 2>/dev/null | head -n 1 || true)"
if [[ -n "$first_container" ]]; then
    detected="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$first_container" 2>/dev/null || true)"
    [[ -z "$project_name" ]] && project_name="$detected"
fi

# Stop tracked host processes first, if future helpers ever place PID files here.
if [[ -d state/pids ]]; then
    shopt -s nullglob
    for pid_file in state/pids/*.pid; do
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            proc_cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
            if [[ "$proc_cwd" == "$PROJECT_ROOT" || "$proc_cwd" == "$PROJECT_ROOT/"* ]]; then
                echo "Stopping tracked host process $pid..."
                kill "$pid" 2>/dev/null || true
                for _ in {1..20}; do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.1
                done
                kill -KILL "$pid" 2>/dev/null || true
            else
                echo "Warning: refusing to kill PID $pid because its working directory is outside this project." >&2
            fi
        fi
        rm -f -- "$pid_file"
    done
    shopt -u nullglob
fi

echo "Stopping and removing project containers, orphans, and Compose networks..."
docker compose --profile runtime down --remove-orphans --timeout 20

# Compose down should remove everything runnable. Sweep only containers carrying
# this project's Compose label in case a prior interrupted Compose operation left
# an orphan behind. Persistent named volumes and images are intentionally kept.
if [[ -n "$project_name" ]]; then
    mapfile -t leftovers < <(docker ps -aq --filter "label=com.docker.compose.project=$project_name")
    if (( ${#leftovers[@]} > 0 )); then
        echo "Removing ${#leftovers[@]} leftover project container(s)..."
        docker rm -f "${leftovers[@]}" >/dev/null
    fi

    mapfile -t networks < <(docker network ls -q --filter "label=com.docker.compose.project=$project_name")
    for network_id in "${networks[@]}"; do
        docker network rm "$network_id" >/dev/null 2>&1 || true
    done

    if docker ps -aq --filter "label=com.docker.compose.project=$project_name" | grep -q .; then
        echo "Error: project containers still remain after shutdown." >&2
        exit 1
    fi
fi

echo "Project runtime stopped completely. Persistent state, downloads/media, images, and named volumes were preserved."
