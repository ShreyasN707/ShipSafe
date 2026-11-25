#!/usr/bin/env bash

PROJECT_DIR=""
REMOTE_HOST=""
REMOTE_USER=""
KEY_PATH=""
SSH_PORT="22"
SSH_TIMEOUT="30"
LOG_DIR="${HOME}/.shipsafe/logs"
PROJECT_TYPE=""

log_error() {
    printf '[shipsafe] Error: %s\n' "$1" >&2
}

parse_deploy_args() {
    if [[ $# -eq 0 ]]; then
        log_error "Missing local project directory."
        return 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                [[ $# -lt 2 ]] && { log_error "--host requires a value."; return 1; }
                REMOTE_HOST="$2"
                shift 2
                ;;
            --user)
                [[ $# -lt 2 ]] && { log_error "--user requires a value."; return 1; }
                REMOTE_USER="$2"
                shift 2
                ;;
            --key)
                [[ $# -lt 2 ]] && { log_error "--key requires a value."; return 1; }
                KEY_PATH="$2"
                shift 2
                ;;
            --port)
                [[ $# -lt 2 ]] && { log_error "--port requires a value."; return 1; }
                SSH_PORT="$2"
                shift 2
                ;;
            --timeout)
                [[ $# -lt 2 ]] && { log_error "--timeout requires a value."; return 1; }
                SSH_TIMEOUT="$2"
                shift 2
                ;;
            --log-dir)
                [[ $# -lt 2 ]] && { log_error "--log-dir requires a value."; return 1; }
                LOG_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$PROJECT_DIR" ]]; then
                    PROJECT_DIR="$1"
                    shift
                else
                    log_error "Unexpected positional argument: $1"
                    return 1
                fi
                ;;
        esac
    done

    if [[ -z "$PROJECT_DIR" || -z "$REMOTE_HOST" || -z "$REMOTE_USER" || -z "$KEY_PATH" ]]; then
        log_error "Required arguments: <project_dir> --host <host> --user <user> --key <key_path>"
        return 1
    fi

    return 0
}

check_local_dependencies() {
    local cmd
    for cmd in ssh date tee basename; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required local command not found: $cmd"
            return 1
        fi
    done

    if ! command -v rsync >/dev/null 2>&1 && ! command -v scp >/dev/null 2>&1; then
        log_error "Either rsync or scp must be installed locally."
        return 1
    fi

    return 0
}

detect_local_project_type() {
    local dir="$1"
    if [[ -f "$dir/compose.yaml" || -f "$dir/compose.yml" || -f "$dir/docker-compose.yaml" || -f "$dir/docker-compose.yml" ]]; then
        PROJECT_TYPE="compose"
        return 0
    fi
    if [[ -f "$dir/Dockerfile" ]]; then
        export PROJECT_TYPE="docker"
        return 0
    fi

    log_error "Unsupported or ambiguous project in '$dir'. Expected compose.yaml, docker-compose.yml, or Dockerfile."
    return 1
}

validate_key_permissions() {
    local key_file="$1"
    local mode

    if [[ ! -e "$key_file" ]]; then
        log_error "SSH private key not found: $key_file"
        return 1
    fi
    if [[ ! -f "$key_file" ]]; then
        log_error "SSH private key path is not a regular file: $key_file"
        return 1
    fi
    if [[ ! -r "$key_file" ]]; then
        log_error "SSH private key is not readable: $key_file"
        return 1
    fi

    if stat -c '%a' "$key_file" >/dev/null 2>&1; then
        mode="$(stat -c '%a' "$key_file")"
    else
        mode="$(stat -f '%Lp' "$key_file")"
    fi

    # OpenSSH rejects keys accessible by group or others.
    local group_other="${mode: -2}"
    if [[ ${#mode} -ge 2 && "$group_other" != "00" ]]; then
        log_error "SSH private key permissions are too open ($mode): $key_file. Run: chmod 600 \"$key_file\""
        return 1
    fi

    return 0
}

validate_deployment_inputs() {
    check_local_dependencies || return 1

    if [[ ! -d "$PROJECT_DIR" ]]; then
        log_error "Local project directory does not exist: $PROJECT_DIR"
        return 1
    fi
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

    if [[ ! "$REMOTE_HOST" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        log_error "Invalid SSH host: $REMOTE_HOST"
        return 1
    fi

    if [[ ! "$REMOTE_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_error "Invalid SSH username: $REMOTE_USER"
        return 1
    fi

    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        log_error "SSH port must be between 1 and 65535: $SSH_PORT"
        return 1
    fi

    if [[ ! "$SSH_TIMEOUT" =~ ^[0-9]+$ ]] || (( SSH_TIMEOUT <= 0 )); then
        log_error "Timeout must be a positive integer: $SSH_TIMEOUT"
        return 1
    fi

    validate_key_permissions "$KEY_PATH" || return 1
    detect_local_project_type "$PROJECT_DIR" || return 1

    mkdir -p "$LOG_DIR"
    LOG_DIR="$(cd "$LOG_DIR" && pwd)"

    return 0
}
