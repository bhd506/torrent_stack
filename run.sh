#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

echo "Creating project directories..."

mkdir -p \
    config/sonarr \
    config/qbittorrent \
    config/prowlarr \
    data/downloads/incomplete \
    data/downloads/tv \
    data/media/tv

echo "Validating Compose configuration..."

docker compose config --quiet

echo "Starting containers..."

docker compose up -d

echo "Running application configuration..."

bash scripts/configure.sh

echo
echo "Torrent stack deployment completed successfully."
echo

docker compose ps
