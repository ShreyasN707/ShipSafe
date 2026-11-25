#!/usr/bin/env bash

REMOTE_DEPLOY_DIR=""

sanitize_app_name() {
    local raw_name="$1"
    local clean
    clean="$(printf '%s' "$raw_name" | tr -cd 'A-Za-z0-9._-')"
    if [[ -z "$clean" ]]; then
        clean="app"
    fi
    printf '%s' "$clean"
}

create_remote_deploy_dir() {
    local target="${REMOTE_USER}@${REMOTE_HOST}"
    local app_name
    app_name="$(sanitize_app_name "$(basename "$PROJECT_DIR")")"
    local unique_id
    unique_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    local rel_dir="shipsafe-deployments/shipsafe-${app_name}-${unique_id}"

    local quoted_rel
    printf -v quoted_rel '%q' "$rel_dir"

    # shellcheck disable=SC2029
    REMOTE_DEPLOY_DIR="$(ssh "${SSH_OPTS[@]}" "$target" "mkdir -p \"\$HOME/${quoted_rel}\" && printf '%s' \"\$HOME/${quoted_rel}\"")" || {
        log_error "Failed to create remote deployment directory."
        return 1
    }

    if [[ -z "$REMOTE_DEPLOY_DIR" ]]; then
        log_error "Remote deployment directory path came back empty."
        return 1
    fi

    printf '[shipsafe] Remote deployment directory: %s\n' "$REMOTE_DEPLOY_DIR"
    return 0
}

transfer_application_files() {
    local target="${REMOTE_USER}@${REMOTE_HOST}"
    local use_rsync=0

    if command -v rsync >/dev/null 2>&1; then
        if ssh "${SSH_OPTS[@]}" "$target" "command -v rsync >/dev/null 2>&1"; then
            use_rsync=1
        fi
    fi

    if [[ $use_rsync -eq 1 ]]; then
        printf '[shipsafe] Transferring files via rsync...\n'
        local ssh_cmd
        printf -v ssh_cmd '%q ' ssh "${SSH_OPTS[@]}"
        rsync -az --exclude='.git/' -e "$ssh_cmd" "${PROJECT_DIR}/" "${target}:${REMOTE_DEPLOY_DIR}/" || {
            log_error "rsync file transfer failed."
            return 1
        }
    else
        printf '[shipsafe] Transferring files via scp...\n'
        local scp_opts=(-r -i "$KEY_PATH" -P "$SSH_PORT" -o "BatchMode=yes" -o "StrictHostKeyChecking=yes" -o "IdentitiesOnly=yes" -o "ConnectTimeout=${SSH_TIMEOUT}")
        scp "${scp_opts[@]}" "${PROJECT_DIR}/." "${target}:${REMOTE_DEPLOY_DIR}/" || {
            log_error "scp file transfer failed."
            return 1
        }
    fi

    return 0
}
