#!/usr/bin/env bash

run_stage() {
    local stage_name="$1"
    shift
    printf '\n[shipsafe] [%s] === %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage_name"
    local status=0
    "$@" || status=$?
    if [[ $status -ne 0 ]]; then
        printf '[shipsafe] [%s] FAILED at stage "%s" (exit code %d)\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage_name" "$status" >&2
        return "$status"
    fi
    return 0
}

execute_remote_deploy() {
    local target="${REMOTE_USER}@${REMOTE_HOST}"
    local remote_script="${SCRIPT_ROOT}/scripts/remote-deploy.sh"

    if [[ ! -f "$remote_script" ]]; then
        log_error "Missing remote deployment script: $remote_script"
        return 1
    fi

    local quoted_dir
    printf -v quoted_dir '%q' "$REMOTE_DEPLOY_DIR"

    local status=0
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$target" "bash -s -- ${quoted_dir}" < "$remote_script" || status=$?

    if [[ $status -eq 255 ]]; then
        log_error "SSH connection dropped during remote deployment (exit 255). The remote process may still be running."
        return 255
    fi

    return "$status"
}

run_pipeline() {
    printf '[shipsafe] Deployment started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[shipsafe] Project       : %s (%s)\n' "$PROJECT_DIR" "$PROJECT_TYPE"
    printf '[shipsafe] Target        : %s@%s:%s\n' "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT"

    run_stage "Verify SSH and remote prerequisites" verify_remote_connection || return $?
    run_stage "Create remote deployment directory" create_remote_deploy_dir || return $?
    run_stage "Transfer application files" transfer_application_files || return $?
    run_stage "Build and start application remotely" execute_remote_deploy || return $?

    printf '\n[shipsafe] [%s] Deployment succeeded.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
}

run_deployment() {
    local app_name
    app_name="$(sanitize_app_name "$(basename "$PROJECT_DIR")")"
    local log_file
    log_file="${LOG_DIR}/shipsafe-${app_name}-$(date -u +%Y%m%d-%H%M%S).log"

    printf '[shipsafe] Log file      : %s\n' "$log_file"

    local pipeline_status=0
    # Piping through tee with pipefail streams output in real time without buffering logs in memory.
    set -o pipefail
    run_pipeline 2>&1 | tee -a "$log_file" || pipeline_status=$?

    if [[ $pipeline_status -ne 0 ]]; then
        printf '[shipsafe] Deployment failed (exit code %d). Full log saved to: %s\n' "$pipeline_status" "$log_file" >&2
        return "$pipeline_status"
    fi

    return 0
}
