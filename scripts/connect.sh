#!/usr/bin/env bash

SSH_OPTS=()

build_ssh_opts() {
    # StrictHostKeyChecking=yes ensures host identity is verified against known_hosts.
    # BatchMode=yes prevents hanging on interactive password prompts.
    SSH_OPTS=(
        -i "$KEY_PATH"
        -p "$SSH_PORT"
        -o "BatchMode=yes"
        -o "StrictHostKeyChecking=yes"
        -o "IdentitiesOnly=yes"
        -o "ConnectTimeout=${SSH_TIMEOUT}"
        -o "ServerAliveInterval=15"
        -o "ServerAliveCountMax=3"
    )
}

verify_remote_connection() {
    build_ssh_opts
    local target="${REMOTE_USER}@${REMOTE_HOST}"

    printf '[shipsafe] Connecting to %s (port %s)...\n' "$target" "$SSH_PORT"

    local remote_check_cmd
    IFS= read -r -d '' remote_check_cmd <<'EOF' || true
set -euo pipefail
printf "OS: %s (%s)\n" "$(uname -s)" "$(uname -m)"
if ! command -v docker >/dev/null 2>&1; then
    printf "Error: docker is not installed on the remote host.\n" >&2
    exit 10
fi
if ! docker info >/dev/null 2>&1; then
    printf "Error: docker daemon is not running or user lacks permission.\n" >&2
    exit 11
fi
if ! docker compose version >/dev/null 2>&1; then
    printf "Error: docker compose plugin is not available on the remote host.\n" >&2
    exit 12
fi
printf "Docker: %s\n" "$(docker --version)"
printf "Compose: %s\n" "$(docker compose version --short)"
EOF

    local status=0
    ssh "${SSH_OPTS[@]}" "$target" "bash -s" <<< "$remote_check_cmd" || status=$?

    if [[ $status -eq 255 ]]; then
        log_error "SSH connection to $target failed (exit 255). Verify host reachability, known_hosts entry, username, and key."
        return 255
    elif [[ $status -ne 0 ]]; then
        log_error "Remote environment verification failed (exit $status)."
        return "$status"
    fi

    return 0
}
