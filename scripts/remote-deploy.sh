#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || -z "$1" ]]; then
    printf '[remote] Error: deployment directory argument is required.\n' >&2
    exit 2
fi

DEPLOY_DIR="$1"
cd "$DEPLOY_DIR"

find_compose_file() {
    local candidate
    for candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

if compose_file="$(find_compose_file)"; then
    printf '[remote] Detected Docker Compose configuration: %s\n' "$compose_file"

    printf '[remote] Building services...\n'
    docker compose -f "$compose_file" build

    printf '[remote] Starting services in detached mode...\n'
    docker compose -f "$compose_file" up -d

    printf '[remote] Verifying running services...\n'
    docker compose -f "$compose_file" ps
    running_ids="$(docker compose -f "$compose_file" ps -q --status running)"
    if [[ -z "$running_ids" ]]; then
        printf '[remote] Error: no running containers detected after docker compose up.\n' >&2
        exit 1
    fi

    printf '[remote] Docker Compose deployment active.\n'
    exit 0
fi

if [[ -f "Dockerfile" ]]; then
    printf '[remote] Detected Dockerfile.\n'
    dir_slug="$(basename "$DEPLOY_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
    image_tag="${dir_slug}:latest"
    container_name="${dir_slug}"

    printf '[remote] Building image %s...\n' "$image_tag"
    docker build -t "$image_tag" .

    printf '[remote] Starting container %s in detached mode...\n' "$container_name"
    docker run -d --name "$container_name" "$image_tag"

    printf '[remote] Verifying running container...\n'
    running_id="$(docker ps -q --filter "name=^/${container_name}$" --filter "status=running")"
    if [[ -z "$running_id" ]]; then
        printf '[remote] Error: container %s is not running after startup.\n' "$container_name" >&2
        docker logs "$container_name" 2>&1 || true
        exit 1
    fi

    printf '[remote] Container %s is running (%s).\n' "$container_name" "$running_id"
    exit 0
fi

printf '[remote] Error: no supported Docker or Docker Compose files found in %s.\n' "$DEPLOY_DIR" >&2
exit 3
