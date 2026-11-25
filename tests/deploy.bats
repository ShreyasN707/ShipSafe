#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SHIPSAFE="${REPO_ROOT}/shipsafe"
    TEST_TMP="$(mktemp -d)"

    PROJECT_DIR="${TEST_TMP}/my app"
    mkdir -p "$PROJECT_DIR"
    printf 'services:\n  web:\n    image: nginx:alpine\n' > "${PROJECT_DIR}/compose.yaml"

    KEY_FILE="${TEST_TMP}/id_ed25519"
    printf 'dummy-key\n' > "$KEY_FILE"
    chmod 600 "$KEY_FILE"

    LOG_DIR="${TEST_TMP}/logs"
    MOCK_BIN="${TEST_TMP}/mock-bin"
    mkdir -p "$MOCK_BIN"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "shows help and version" {
    run "$SHIPSAFE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"shipsafe deploy"* ]]

    run "$SHIPSAFE" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"shipsafe "* ]]
}

@test "fails on missing required arguments" {
    run "$SHIPSAFE" deploy "$PROJECT_DIR" --host 192.168.1.50
    [ "$status" -eq 2 ]
    [[ "$output" == *"Required arguments"* ]]
}

@test "fails when project directory does not exist" {
    run "$SHIPSAFE" deploy "${TEST_TMP}/missing" \
        --host 192.168.1.50 --user deploy --key "$KEY_FILE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "fails when private key permissions are too open" {
    chmod 644 "$KEY_FILE"
    run "$SHIPSAFE" deploy "$PROJECT_DIR" \
        --host 192.168.1.50 --user deploy --key "$KEY_FILE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"permissions are too open"* ]]
}

@test "fails on unsafe host or username" {
    run "$SHIPSAFE" deploy "$PROJECT_DIR" \
        --host "192.168.1.50;id" --user deploy --key "$KEY_FILE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Invalid SSH host"* ]]

    run "$SHIPSAFE" deploy "$PROJECT_DIR" \
        --host 192.168.1.50 --user "deploy && id" --key "$KEY_FILE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Invalid SSH username"* ]]
}

@test "fails on unsupported project without Dockerfile or Compose" {
    local plain_dir="${TEST_TMP}/plain"
    mkdir -p "$plain_dir"
    run "$SHIPSAFE" deploy "$plain_dir" \
        --host 192.168.1.50 --user deploy --key "$KEY_FILE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unsupported or ambiguous project"* ]]
}

@test "succeeds and writes timestamped log with mocked ssh and rsync" {
    cat > "${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${*: -1}"
if [[ "$cmd" == *"mkdir -p"* ]]; then
    printf '/home/deploy/shipsafe-deployments/shipsafe-myapp-test'
    exit 0
fi
if [[ "$cmd" == *"command -v rsync"* ]]; then
    exit 0
fi
if [[ "$cmd" == "bash -s" ]]; then
    cat >/dev/null
    printf 'OS: Linux (x86_64)\nDocker: Docker version 27.0.0\nCompose: 2.29.0\n'
    exit 0
fi
if [[ "$cmd" == *"bash -s --"* ]]; then
    cat >/dev/null
    printf '[remote] Building services...\n[remote] Docker Compose deployment active.\n'
    exit 0
fi
exit 0
EOF
    cat > "${MOCK_BIN}/rsync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${MOCK_BIN}/ssh" "${MOCK_BIN}/rsync"

    PATH="${MOCK_BIN}:${PATH}" run "$SHIPSAFE" deploy "$PROJECT_DIR" \
        --host 192.168.1.50 --user deploy --key "$KEY_FILE" --log-dir "$LOG_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment succeeded."* ]]

    local log_count
    log_count="$(find "$LOG_DIR" -name 'shipsafe-*.log' | wc -l | tr -d ' ')"
    [ "$log_count" -eq 1 ]

    local log_file
    log_file="$(find "$LOG_DIR" -name 'shipsafe-*.log' | head -n 1)"
    grep -q "Docker Compose deployment active." "$log_file"
}

@test "reports failure and preserves log when remote deployment fails" {
    cat > "${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${*: -1}"
if [[ "$cmd" == *"mkdir -p"* ]]; then
    printf '/home/deploy/shipsafe-deployments/shipsafe-myapp-test'
    exit 0
fi
if [[ "$cmd" == *"command -v rsync"* ]]; then
    exit 0
fi
if [[ "$cmd" == "bash -s" ]]; then
    cat >/dev/null
    exit 0
fi
if [[ "$cmd" == *"bash -s --"* ]]; then
    cat >/dev/null
    printf '[remote] Build failed!\n' >&2
    exit 1
fi
exit 0
EOF
    cat > "${MOCK_BIN}/rsync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${MOCK_BIN}/ssh" "${MOCK_BIN}/rsync"

    PATH="${MOCK_BIN}:${PATH}" run "$SHIPSAFE" deploy "$PROJECT_DIR" \
        --host 192.168.1.50 --user deploy --key "$KEY_FILE" --log-dir "$LOG_DIR"

    [ "$status" -eq 1 ]
    [[ "$output" == *'FAILED at stage "Build and start application remotely"'* ]]

    local log_file
    log_file="$(find "$LOG_DIR" -name 'shipsafe-*.log' | head -n 1)"
    [ -f "$log_file" ]
    grep -q "Build failed!" "$log_file"
}

@test "reports SSH 255 connection failure clearly" {
    cat > "${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
    chmod +x "${MOCK_BIN}/ssh"

    PATH="${MOCK_BIN}:${PATH}" run "$SHIPSAFE" deploy "$PROJECT_DIR" \
        --host 192.168.1.50 --user deploy --key "$KEY_FILE" --log-dir "$LOG_DIR"

    [ "$status" -eq 255 ]
    [[ "$output" == *"SSH connection to deploy@192.168.1.50 failed (exit 255)"* ]]
}
