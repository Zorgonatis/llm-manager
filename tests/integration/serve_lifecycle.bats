#!/usr/bin/env bats
# serve_lifecycle.bats — Integration tests for llm-manager serve/start/stop lifecycle
#
# Uses the real llama.cpp CPU binary and downloads Qwen3-0.6B from HuggingFace
# on first run (~600MB, cached thereafter by HF).
#
# Gating: skips entire file if /data-fast/apps/llama.cpp/llama-server is missing.

load '../bats-support/load'
load '../bats-assert/load'
load '../test_helper'

# ── Suite-level gate: skip everything if binary missing ────────────────────
setup_file() {
    if [ ! -x /data-fast/apps/llama.cpp/llama-server ]; then
        skip "llama-server binary not found at /data-fast/apps/llama.cpp/llama-server"
    fi
}

# ── Per-test setup / teardown ──────────────────────────────────────────────
setup() {
    setup_test_env
    # Read the test port from the fixture config so we don't hardcode it
    TEST_PORT="$(grep -E '^service_port=' "$LLM_CONF" | head -1 | cut -d= -f2 | tr -d ' "')" 
    TEST_PORT="${TEST_PORT:-14444}"

    # Skip this test if something is already listening on the port
    if ss -tlnp 2>/dev/null | grep -q ":${TEST_PORT} " \
       || curl -s "http://127.0.0.1:${TEST_PORT}" >/dev/null 2>&1; then
        skip "Port ${TEST_PORT} is already in use — cannot run this test"
    fi
}

teardown() {
    # Kill any llama-server on the test port (best-effort, swallow errors)
    local pids
    pids="$(ss -tlnp 2>/dev/null | grep ":${TEST_PORT:-14444} " | grep -oP 'pid=\K[0-9]+' || true)"
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    # Also clean up via PID files the launcher may have written
    if [ -d "${TEST_DIR:-}" ]; then
        for pidfile in "$TEST_DIR"/instances/*.pid; do
            [ -f "$pidfile" ] || continue
            local pid
            pid="$(cat "$pidfile" 2>/dev/null || true)"
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        done
    fi
    # Give processes a moment to die, then force
    sleep 0.5
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
    cleanup_test_env
}

# ── Helper: source lib.sh + launcher.sh into test env ──────────────────────
_source_project() {
    source_lib
    source_launcher
    # Re-override vars that launcher.sh hardcoded to its own script dir
    export LLM_DIR="$TEST_DIR"
    export MODELS_CONF="$TEST_DIR/models.conf"
    export LLM_CONF="$TEST_DIR/llm.conf"
    CURRENT_MODEL_FILE="$TEST_DIR/current_model"
    INSTANCES_DIR="$TEST_DIR/instances"
    LOGS_DIR="$TEST_DIR/logs"
    SERVICE_FILE="$TEST_DIR/llm.service"
    mkdir -p "$INSTANCES_DIR" "$LOGS_DIR"
    # launcher.sh has set -e; disable for test assertions on expected failures
    set +e
}

# ── Helper: wait for the health endpoint ───────────────────────────────────
# llama.cpp exposes /health once the model is loaded and ready.
_wait_healthy() {
    local port="$1"
    local timeout="${2:-120}"
    local elapsed=0
    while [ "$elapsed" -lt "$((timeout * 2))" ]; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        # /health returns 200 with {"status":"ok"} when ready
        local status
        status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/health" 2>/dev/null || true)"
        if [ "$status" = "200" ]; then
            return 0
        fi
        # Also accept if the root path responds (older builds)
        if curl -s "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# ── Helper: kill process from PID file and wait for port to free ───────────
_kill_and_wait_port_free() {
    local port="$1"
    local timeout="${2:-10}"
    # Find PID via ss as fallback
    local pids
    pids="$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' || true)"
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    local elapsed=0
    while [ "$elapsed" -lt "$((timeout * 2))" ]; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if ! curl -s "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            return 0
        fi
    done
    # Force kill
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
    return 1
}

# ============================================================================
# TEST: Instance lifecycle — start → health → stop
# ============================================================================

@test "start_instance: test-tiny starts and health endpoint responds" {
    _source_project

    # Determine timeout: generous on first run (model download ~700MB)
    local timeout=120

    run start_instance test-tiny --port "$TEST_PORT"
    [ "$status" -eq 0 ]

    # Wait for the server to become healthy
    _wait_healthy "$TEST_PORT" "$timeout"

    # Verify health endpoint explicitly
    local health_status
    health_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${TEST_PORT}/health" 2>/dev/null)"
    [ "$health_status" = "200" ] || [ "$health_status" = "307" ]

    # Verify PID file exists and process is alive
    [ -f "$INSTANCES_DIR/$TEST_PORT.pid" ]
    local pid
    pid="$(cat "$INSTANCES_DIR/$TEST_PORT.pid")"
    ps -p "$pid" >/dev/null 2>&1
}

@test "stop_instance: stops the running instance and frees the port" {
    _source_project

    # Start first
    start_instance test-tiny --port "$TEST_PORT" >/dev/null 2>&1 || true
    _wait_healthy "$TEST_PORT" 120

    # Now stop it
    run stop_instance stop --port "$TEST_PORT"
    [ "$status" -eq 0 ]

    # PID file should be removed
    [ ! -f "$INSTANCES_DIR/$TEST_PORT.pid" ]

    # Port should be freed within a few seconds
    _kill_and_wait_port_free "$TEST_PORT" 10
    ! curl -s "http://127.0.0.1:${TEST_PORT}/" >/dev/null 2>&1
}

@test "start_instance --port override: starts on custom port" {
    _source_project

    local custom_port=$((TEST_PORT + 1))

    # Make sure the custom port is free
    if ss -tlnp 2>/dev/null | grep -q ":${custom_port} "; then
        skip "Custom port ${custom_port} already in use"
    fi

    run start_instance test-tiny --port "$custom_port"
    [ "$status" -eq 0 ]

    _wait_healthy "$custom_port" 120

    local health_status
    health_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${custom_port}/health" 2>/dev/null)"
    [ "$health_status" = "200" ] || [ "$health_status" = "307" ]

    # Clean up
    _kill_and_wait_port_free "$custom_port" 10
}

@test "start_instance when port occupied: returns error" {
    _source_project

    # Occupy the port with a quick listener using the launcher itself
    start_instance test-tiny --port "$TEST_PORT" >/dev/null 2>&1 || true
    _wait_healthy "$TEST_PORT" 120

    # Second start on same port should fail
    run start_instance test-tiny --port "$TEST_PORT"
    [ "$status" -ne 0 ]
}

# ============================================================================
# TEST: Direct binary invocation — build_cmdline + exec
# ============================================================================

@test "build_cmdline: test-tiny produces correct command line" {
    _source_project

    build_cmdline "test-tiny" "$TEST_PORT" "cpu" ""

    # Join array for inspection
    local cmdline="${CMD_ARRAY[*]}"

    # Must contain the binary path
    [[ "$cmdline" == *"/data-fast/apps/llama.cpp/llama-server"* ]]

    # Must contain the HF model spec
    [[ "$cmdline" == *"-hf"* ]]
    [[ "$cmdline" == *"Qwen/Qwen3-0.6B-GGUF"* ]]

    # Must contain model-level args
    [[ "$cmdline" == *"--ctx-size 2048"* ]]

    # Must contain host and port
    [[ "$cmdline" == *"--host 127.0.0.1"* ]]
    [[ "$cmdline" == *"--port ${TEST_PORT}"* ]]

    # Must NOT contain --device (cpu backend has no device configured)
    [[ "$cmdline" != *"--device"* ]]

    # Must contain the backend extra_args (--alias test)
    [[ "$cmdline" == *"--alias test"* ]]
}

@test "build_cmdline + exec: actually runs the server and responds to health" {
    _source_project

    build_cmdline "test-tiny" "$TEST_PORT" "cpu" ""

    # Start in background (mimicking what start_instance does)
    local log_file="$LOGS_DIR/instance-${TEST_PORT}.log"
    mkdir -p "$LOGS_DIR"

    nohup "${CMD_ARRAY[@]}" >> "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$INSTANCES_DIR/${TEST_PORT}.pid"

    # Wait for health
    _wait_healthy "$TEST_PORT" 120

    # Verify the server process is alive
    ps -p "$pid" >/dev/null 2>&1

    # Clean up
    kill "$pid" 2>/dev/null || true
    _kill_and_wait_port_free "$TEST_PORT" 10
}

@test "build_cmdline + stop: port freed after stopping process" {
    _source_project

    build_cmdline "test-tiny" "$TEST_PORT" "cpu" ""

    local log_file="$LOGS_DIR/instance-${TEST_PORT}.log"
    mkdir -p "$LOGS_DIR"

    nohup "${CMD_ARRAY[@]}" >> "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$INSTANCES_DIR/${TEST_PORT}.pid"

    _wait_healthy "$TEST_PORT" 120

    # Now stop via stop_instance
    stop_instance stop --port "$TEST_PORT" >/dev/null 2>&1 || true

    # Port must be freed
    _kill_and_wait_port_free "$TEST_PORT" 10
    ! curl -s "http://127.0.0.1:${TEST_PORT}/" >/dev/null 2>&1
}

# ============================================================================
# TEST: Profile merging — test-max uses profile=max
# ============================================================================

@test "profile merging: test-max includes max profile flags in command line" {
    _source_project

    build_cmdline "test-max" "$TEST_PORT" "cpu" ""

    local cmdline="${CMD_ARRAY[*]}"

    # Profile flags must be present
    [[ "$cmdline" == *"--ctx-size 262144"* ]]
    [[ "$cmdline" == *"--cache-type-v q8_0"* ]]
    [[ "$cmdline" == *"--cache-type-k q8_0"* ]]
    [[ "$cmdline" == *"--parallel 1"* ]]
    [[ "$cmdline" == *"--flash-attn auto"* ]]
    [[ "$cmdline" == *"--jinja"* ]]
    [[ "$cmdline" == *"--no-mmap"* ]]

    # Model-level args should also be present
    [[ "$cmdline" == *"-hf"* ]]
    [[ "$cmdline" == *"Qwen/Qwen3-0.6B-GGUF"* ]]

    # Model-level temp should be present (from model args)
    [[ "$cmdline" == *"--temp 0.6"* ]]

    # Host/port
    [[ "$cmdline" == *"--host 127.0.0.1"* ]]
    [[ "$cmdline" == *"--port ${TEST_PORT}"* ]]
}

@test "profile merging: test-max actually serves and responds" {
    _source_project

    build_cmdline "test-max" "$TEST_PORT" "cpu" ""

    local log_file="$LOGS_DIR/instance-${TEST_PORT}.log"
    mkdir -p "$LOGS_DIR"

    nohup "${CMD_ARRAY[@]}" >> "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$INSTANCES_DIR/${TEST_PORT}.pid"

    _wait_healthy "$TEST_PORT" 120

    # Verify it's alive
    ps -p "$pid" >/dev/null 2>&1

    local health_status
    health_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${TEST_PORT}/health" 2>/dev/null)"
    [ "$health_status" = "200" ] || [ "$health_status" = "307" ]

    # Clean up
    kill "$pid" 2>/dev/null || true
    _kill_and_wait_port_free "$TEST_PORT" 10
}

# ============================================================================
# TEST: Device injection — test-device-override uses vulkan backend
#         with explicit --device in model args → backend device NOT injected
# ============================================================================

@test "device injection: test-device-override uses model --device, not backend's" {
    _source_project

    # test-device-override uses backend=vulkan but specifies --device Vulkan0,Vulkan1
    # in its own args. The build_cmdline should detect the existing --device and
    # NOT inject the backend's device (which is "Vulkan0" from llm.conf).
    #
    # NOTE: vulkan backend binary likely doesn't exist on test machine, but
    # build_cmdline doesn't validate the binary — it just builds the array.
    # We validate the cmdline content only.

    build_cmdline "test-device-override" "$TEST_PORT" "vulkan" "max"

    local cmdline="${CMD_ARRAY[*]}"

    # The binary path for vulkan backend
    [[ "$cmdline" == *"/data-fast/apps/llama.cpp/install-vulkan/bin/llama-server"* ]]

    # Must contain the model's --device Vulkan0,Vulkan1 (from model args)
    # We check for the presence of both Vulkan0 and Vulkan1 in a --device flag
    # The exact format depends on arg ordering, but the model args include:
    #   --device Vulkan0,Vulkan1
    [[ "$cmdline" == *"Vulkan0,Vulkan1"* ]]

    # Must NOT contain a second --device with just the backend's Vulkan0
    # Count occurrences of "Vulkan0" — should appear only once (as part of Vulkan0,Vulkan1)
    local vulkan0_count
    vulkan0_count="$(echo "$cmdline" | grep -o 'Vulkan0' | wc -l)"
    # Vulkan0 appears once in "Vulkan0,Vulkan1"
    [ "$vulkan0_count" -eq 1 ]

    # Profile max flags should be present (test-device-override uses profile=max)
    [[ "$cmdline" == *"--ctx-size 262144"* ]]
    [[ "$cmdline" == *"--cache-type-v q8_0"* ]]

    # Model args should also be present
    [[ "$cmdline" == *"Qwen/Qwen3-0.6B-GGUF"* ]]
    [[ "$cmdline" == *"--temp 0.8"* ]]

    # Host/port
    [[ "$cmdline" == *"--host 127.0.0.1"* ]]
    [[ "$cmdline" == *"--port ${TEST_PORT}"* ]]
}
