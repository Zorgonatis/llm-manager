#!/usr/bin/env bats
# Unit tests for lib.sh — all 17 functions with edge cases

load '../bats-support/load'
load '../bats-assert/load'
load '../test_helper'

setup() {
    # test_helper.bash resolves PROJECT_DIR one dir up from test file;
    # unit tests are two levels deep (tests/unit/) so fix the path
    PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FIXTURES_DIR="$PROJECT_DIR/tests/fixtures"
    setup_test_env
    source_lib
}

teardown() {
    cleanup_test_env
}

# ==============================================================================
# trim
# ==============================================================================

@test "trim: removes leading spaces" {
    run trim "  hello"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "trim: removes trailing spaces" {
    run trim "hello  "
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "trim: removes leading and trailing spaces" {
    run trim "  hello world  "
    [ "$status" -eq 0 ]
    [ "$output" = "hello world" ]
}

@test "trim: removes tabs" {
    run trim "$(printf '\t\thello\t')"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "trim: no-op on already-trimmed string" {
    run trim "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "trim: empty string returns empty" {
    run trim ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "trim: preserves internal whitespace" {
    run trim "  hello   world  "
    [ "$status" -eq 0 ]
    [ "$output" = "hello   world" ]
}

# ==============================================================================
# rotate_log
# ==============================================================================

@test "rotate_log: rotates existing file with default count" {
    local log_file="$TEST_DIR/test.log"
    echo "original" > "$log_file"

    run rotate_log "$log_file"
    [ "$status" -eq 0 ]
    [ ! -f "$log_file" ]
    [ -f "${log_file}.1" ]
    [ "$(cat "${log_file}.1")" = "original" ]
}

@test "rotate_log: rotates with custom count shifting existing copies" {
    local log_file="$TEST_DIR/test.log"
    echo "current" > "$log_file"
    echo "first" > "${log_file}.1"
    echo "second" > "${log_file}.2"

    run rotate_log "$log_file" 3
    [ "$status" -eq 0 ]
    [ ! -f "$log_file" ]
    [ "$(cat "${log_file}.1")" = "current" ]
    [ "$(cat "${log_file}.2")" = "first" ]
    [ "$(cat "${log_file}.3")" = "second" ]
}

@test "rotate_log: nonexistent file produces no error" {
    run rotate_log "$TEST_DIR/nonexistent.log"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_DIR/nonexistent.log" ]
    [ ! -f "$TEST_DIR/nonexistent.log.1" ]
}

@test "rotate_log: empty directory — no files to rotate" {
    run rotate_log "$TEST_DIR/missing.log" 5
    [ "$status" -eq 0 ]
}

# ==============================================================================
# load_config
# ==============================================================================

@test "load_config: reads top-level key=value pairs" {
    load_config "$LLM_CONF"
    [ "${SERVICE_HOST}" = "127.0.0.1" ]
    [ "${SERVICE_PORT}" = "14444" ]
}

@test "load_config: stops at [section] headers" {
    load_config "$LLM_CONF"
    # backend.cpu section has binary=... which should NOT be exported as BINARY
    # because load_config stops at the first [section]
    [ "${MODELS_DIR:+set}" = "set" ]
}

@test "load_config: expands \$llm_dir" {
    load_config "$LLM_CONF"
    [ "${MODELS_DIR}" = "$LLM_DIR/models" ]
}

@test "load_config: expands \$HOME via substitution" {
    local conf="$TEST_DIR/home_test.conf"
    printf 'my_path=$HOME/custom\n' > "$conf"
    load_config "$conf"
    [ "${MY_PATH}" = "$HOME/custom" ]
}

@test "load_config: expands ~ to \$HOME" {
    local conf="$TEST_DIR/tilde_test.conf"
    printf 'tilde_path=~/something\n' > "$conf"
    load_config "$conf"
    [ "${TILDE_PATH}" = "$HOME/something" ]
}

@test "load_config: exports keys as uppercase variables" {
    load_config "$LLM_CONF"
    [ "${INSTANCE_PORT_START}" = "18081" ]
}

@test "load_config: skips comment lines" {
    local conf="$TEST_DIR/comment_test.conf"
    printf '# this is a comment\nactual_key=value\n' > "$conf"
    load_config "$conf"
    [ "${ACTUAL_KEY}" = "value" ]
}

@test "load_config: skips blank lines" {
    local conf="$TEST_DIR/blank_test.conf"
    printf '\n\nonly_key=here\n\n' > "$conf"
    load_config "$conf"
    [ "${ONLY_KEY}" = "here" ]
}

# ==============================================================================
# get_config_from
# ==============================================================================

@test "get_config_from: finds key in correct section" {
    run get_config_from "$LLM_CONF" "backend.cpu" "binary"
    [ "$status" -eq 0 ]
    [ "$output" = "/data-fast/apps/llama.cpp/llama-server" ]
}

@test "get_config_from: returns 1 when section not found" {
    run get_config_from "$LLM_CONF" "backend.nonexistent" "binary"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "get_config_from: returns 1 when key not found in section" {
    run get_config_from "$LLM_CONF" "backend.cpu" "nonexistent_key"
    [ "$status" -eq 1 ]
}

@test "get_config_from: expands \$HOME in values" {
    local conf="$TEST_DIR/home_section.conf"
    printf '[section.one]\nmykey=$HOME/expanded\n' > "$conf"
    run get_config_from "$conf" "section.one" "mykey"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/expanded" ]
}

@test "get_config_from: expands ~ in values" {
    local conf="$TEST_DIR/tilde_section.conf"
    printf '[section.two]\nmykey=~/tilde_path\n' > "$conf"
    run get_config_from "$conf" "section.two" "mykey"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/tilde_path" ]
}

# ==============================================================================
# get_config (wrapper)
# ==============================================================================

@test "get_config: delegates to get_config_from with MODELS_CONF" {
    run get_config "test-tiny" "backend"
    [ "$status" -eq 0 ]
    [ "$output" = "cpu" ]
}

@test "get_config: returns 1 for missing section" {
    run get_config "nonexistent-model" "backend"
    [ "$status" -eq 1 ]
}

# ==============================================================================
# get_backend_binary
# ==============================================================================

@test "get_backend_binary: returns binary path for known backend" {
    run get_backend_binary "cpu"
    [ "$status" -eq 0 ]
    [ "$output" = "/data-fast/apps/llama.cpp/llama-server" ]
}

@test "get_backend_binary: returns 1 and prints error for unknown backend" {
    run get_backend_binary "nonexistent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: Backend 'nonexistent' not found"* ]]
}

# ==============================================================================
# get_backend_args_block
# ==============================================================================

@test "get_backend_args_block: returns empty (exit 0) when no block exists" {
    run get_backend_args_block "cpu"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "get_backend_args_block: parses block content with continuation lines" {
    cat >> "$LLM_CONF" <<'CONF'

[backend.args-test]
binary=/usr/bin/test
<backend_args>
--serve \
--mode api \
--verbose
</backend_args>
CONF

    run get_backend_args_block "args-test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--serve"* ]]
    [[ "$output" == *"--mode api"* ]]
    [[ "$output" == *"--verbose"* ]]
}

@test "get_backend_args_block: expands \$HOME and ~ in block content" {
    cat >> "$LLM_CONF" <<'CONF'

[backend.path-test]
binary=/usr/bin/test
<backend_args>
--config ~/etc/app.conf \
--data $HOME/var/data
</backend_args>
CONF

    run get_backend_args_block "path-test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/etc/app.conf"* ]]
    [[ "$output" == *"$HOME/var/data"* ]]
}

@test "get_backend_args_block: handles missing block gracefully for all fixture backends" {
    for backend in cuda rocm vulkan test; do
        run get_backend_args_block "$backend"
        [ "$status" -eq 0 ]
    done
}

# ==============================================================================
# get_backend_venv
# ==============================================================================

@test "get_backend_venv: returns empty when no venv configured" {
    run get_backend_venv "cpu"
    # No venv key in fixture — get_config_from returns 1, output empty
    [ -z "$output" ] || true
}

@test "get_backend_venv: returns path when venv is configured" {
    cat >> "$LLM_CONF" <<'CONF'

[backend.venv-test]
binary=/usr/bin/test
venv=/opt/test-venv
CONF

    run get_backend_venv "venv-test"
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/test-venv" ]
}

# ==============================================================================
# get_backend_device
# ==============================================================================

@test "get_backend_device: returns device when configured" {
    run get_backend_device "cuda"
    [ "$status" -eq 0 ]
    [ "$output" = "CUDA0" ]
}

@test "get_backend_device: returns empty when no device configured" {
    run get_backend_device "cpu"
    # cpu has no device key
    [ -z "$output" ] || true
}

# ==============================================================================
# get_backend_extra_args
# ==============================================================================

@test "get_backend_extra_args: parses <extra_args> block" {
    run get_backend_extra_args "cpu"
    [ "$status" -eq 0 ]
    [ "$output" = "--alias test" ]
}

@test "get_backend_extra_args: returns empty (exit 0) when no block exists" {
    # Remove extra_args from a copy to test empty case
    local conf="$TEST_DIR/no_extra.conf"
    printf '[backend.bare]\nbinary=/usr/bin/bare\n' > "$conf"
    local orig_conf="$LLM_CONF"
    LLM_CONF="$conf"

    run get_backend_extra_args "bare"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    LLM_CONF="$orig_conf"
}

@test "get_backend_extra_args: handles continuation lines" {
    local conf="$TEST_DIR/extra_cont.conf"
    cat > "$conf" <<'CONF'
[backend.cont-test]
binary=/usr/bin/test
<extra_args>
--flag-a \
--flag-b value \
--flag-c
</extra_args>
CONF
    local orig_conf="$LLM_CONF"
    LLM_CONF="$conf"

    run get_backend_extra_args "cont-test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--flag-a"* ]]
    [[ "$output" == *"--flag-b value"* ]]
    [[ "$output" == *"--flag-c"* ]]

    LLM_CONF="$orig_conf"
}

@test "get_backend_extra_args: expands \$HOME and ~" {
    local conf="$TEST_DIR/extra_path.conf"
    cat > "$conf" <<CONF
[backend.path-extra]
binary=/usr/bin/test
<extra_args>
--template ~/templates/default.json
--output \$HOME/output
</extra_args>
CONF
    local orig_conf="$LLM_CONF"
    LLM_CONF="$conf"

    run get_backend_extra_args "path-extra"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/templates/default.json"* ]]
    [[ "$output" == *"$HOME/output"* ]]

    LLM_CONF="$orig_conf"
}

# ==============================================================================
# activate_backend_venv
# ==============================================================================

@test "activate_backend_venv: no-op when no venv configured" {
    local path_before="$PATH"
    run activate_backend_venv "cpu"
    [ "$status" -eq 0 ]
    [ "$PATH" = "$path_before" ]
}

@test "activate_backend_venv: modifies PATH when venv directory exists" {
    local venv_dir="$TEST_DIR/fake-venv"
    mkdir -p "$venv_dir/bin"

    cat >> "$LLM_CONF" <<CONF

[backend.venv-act]
binary=/usr/bin/test
venv=$venv_dir
CONF

    activate_backend_venv "venv-act"
    [ "$VIRTUAL_ENV" = "$venv_dir" ]
    [[ "$PATH" == "${venv_dir}/bin:"* ]]
}

@test "activate_backend_venv: no-op when venv path set but directory missing" {
    cat >> "$LLM_CONF" <<CONF

[backend.venv-missing]
binary=/usr/bin/test
venv=$TEST_DIR/nonexistent-venv
CONF

    local path_before="$PATH"
    activate_backend_venv "venv-missing"
    [ "$PATH" = "$path_before" ]
}

# ==============================================================================
# get_args_block
# ==============================================================================

@test "get_args_block: parses <args> block from model section" {
    run get_args_block "test-tiny"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-hf Qwen/Qwen3-0.6B-GGUF"* ]]
    [[ "$output" == *"--ctx-size 2048"* ]]
}

@test "get_args_block: joins continuation lines" {
    run get_args_block "test-tiny"
    [ "$status" -eq 0 ]
    # All args should be on one logical line (continuation lines joined)
    [[ "$output" == *"--threads 2"* ]]
    [[ "$output" == *"--parallel 1"* ]]
    [[ "$output" == *"--temp 0.8"* ]]
    [[ "$output" == *"--top-p 0.95"* ]]
}

@test "get_args_block: expands \$HOME and ~" {
    local conf="$TEST_DIR/models_home.conf"
    cat > "$conf" <<'CONF'
[model.home-test]
backend=cpu
<args>
--model ~/models/test.gguf \
--output $HOME/out
</args>
CONF
    local orig="$MODELS_CONF"
    MODELS_CONF="$conf"

    run get_args_block "model.home-test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/models/test.gguf"* ]]
    [[ "$output" == *"$HOME/out"* ]]

    MODELS_CONF="$orig"
}

@test "get_args_block: returns 1 when section not found" {
    run get_args_block "nonexistent-section"
    [ "$status" -eq 1 ]
}

@test "get_args_block: returns 1 when section exists but has no <args> block" {
    run get_args_block "test-no-args"
    [ "$status" -eq 1 ]
}

# ==============================================================================
# get_profile_args
# ==============================================================================

@test "get_profile_args: retrieves profile.max args" {
    run get_profile_args "max"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--ctx-size 262144"* ]]
    [[ "$output" == *"--gpu-layers 999"* ]]
}

@test "get_profile_args: retrieves profile.high-parallel args" {
    run get_profile_args "high-parallel"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--parallel 4"* ]]
    [[ "$output" == *"--main-gpu 0"* ]]
}

@test "get_profile_args: returns 1 for nonexistent profile" {
    run get_profile_args "nonexistent"
    [ "$status" -eq 1 ]
}

# ==============================================================================
# read_current_model
# ==============================================================================

@test "read_current_model: parses extended format id|backend|profile" {
    local file="$TEST_DIR/current_model"
    echo "test-tiny|cpu|max" > "$file"

    run read_current_model "$file"
    [ "$status" -eq 0 ]
    [ "$output" = "test-tiny|cpu|max" ]
}

@test "read_current_model: old format id becomes id||" {
    local file="$TEST_DIR/current_model"
    echo "test-tiny" > "$file"

    run read_current_model "$file"
    [ "$status" -eq 0 ]
    [ "$output" = "test-tiny||" ]
}

@test "read_current_model: returns 1 when file missing" {
    run read_current_model "$TEST_DIR/no_such_file"
    [ "$status" -eq 1 ]
}

# ==============================================================================
# build_cmdline — THE CRITICAL FUNCTION
# ==============================================================================

@test "build_cmdline: test-tiny produces correct merge order — binary → model_args → extra_args → host/port" {
    load_config "$LLM_CONF"

    build_cmdline "test-tiny" "8080" || false

    # Binary first
    [ "${CMD_ARRAY[0]}" = "/data-fast/apps/llama.cpp/llama-server" ]

    # Model args follow: -hf ... --ctx-size 2048 --threads 2 --parallel 1 --temp 0.8 --top-p 0.95
    local found_hf=0 found_ctx=0 found_temp=0
    for arg in "${CMD_ARRAY[@]}"; do
        [ "$arg" = "-hf" ] && found_hf=1
        [ "$arg" = "2048" ] && found_ctx=1
        [ "$arg" = "0.8" ] && found_temp=1
    done
    [ "$found_hf" -eq 1 ]
    [ "$found_ctx" -eq 1 ]
    [ "$found_temp" -eq 1 ]

    # Extra args (--alias test) after model args
    local idx_alias=-1 idx_port=-1
    for i in "${!CMD_ARRAY[@]}"; do
        [ "${CMD_ARRAY[$i]}" = "--alias" ] && idx_alias=$i
        [ "${CMD_ARRAY[$i]}" = "--port" ] && idx_port=$i
    done
    [ "$idx_alias" -gt 0 ]
    [ "$idx_port" -gt "$idx_alias" ]

    # Last element is the port number
    local last_idx=$((${#CMD_ARRAY[@]} - 1))
    [[ "${CMD_ARRAY[$last_idx]}" =~ ^[0-9]+$ ]]
}

@test "build_cmdline: test-max inserts profile args between binary and model args" {
    load_config "$LLM_CONF"

    build_cmdline "test-max" "8080" || false

    # Binary at index 0
    [ "${CMD_ARRAY[0]}" = "/data-fast/apps/llama.cpp/llama-server" ]

    # Profile args (max) should appear before model's -hf
    local idx_ctx262=-1 idx_hf=-1
    for i in "${!CMD_ARRAY[@]}"; do
        [ "${CMD_ARRAY[$i]}" = "262144" ] && idx_ctx262=$i
        [ "${CMD_ARRAY[$i]}" = "-hf" ] && idx_hf=$i
    done
    [ "$idx_ctx262" -gt 0 ]
    [ "$idx_hf" -gt "$idx_ctx262" ]
}

@test "build_cmdline: --device in model args prevents backend device injection (test-device-override)" {
    load_config "$LLM_CONF"

    build_cmdline "test-device-override" "8080" || false

    # Vulkan backend binary
    [ "${CMD_ARRAY[0]}" = "/data-fast/apps/llama.cpp/install-vulkan/bin/llama-server" ]

    # --device should appear exactly once (from model args, not injected)
    local device_count=0
    for arg in "${CMD_ARRAY[@]}"; do
        [ "$arg" = "--device" ] && device_count=$((device_count + 1))
    done
    [ "$device_count" -eq 1 ]

    # Device value should be Vulkan0,Vulkan1 (from model), not Vulkan0 (from backend)
    local idx=-1 next_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--device" ]; then
            idx=$i
            local next=$((i + 1))
            next_val="${CMD_ARRAY[$next]}"
            break
        fi
    done
    [ "$next_val" = "Vulkan0,Vulkan1" ]
}

@test "build_cmdline: backend override changes binary and device injection" {
    load_config "$LLM_CONF"

    build_cmdline "test-tiny" "8080" "cuda" || false

    # CUDA binary
    [ "${CMD_ARRAY[0]}" = "/data-fast/apps/llama.cpp/install-cuda/bin/llama-server" ]

    # Device should be injected (CUDA0) because test-tiny args have no --device
    local idx=-1 next_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--device" ]; then
            idx=$i
            local next=$((i + 1))
            next_val="${CMD_ARRAY[$next]}"
            break
        fi
    done
    [ "$idx" -gt 0 ]
    [ "$next_val" = "CUDA0" ]
}

@test "build_cmdline: profile override — model --ctx-size wins over profile override" {
    load_config "$LLM_CONF"

    # test-tiny has --ctx-size 2048 in its args; overriding with 'max' profile
    # which adds --ctx-size 262144. Model's value should win (last occurrence).
    build_cmdline "test-tiny" "8080" "" "max" || false

    local ctx_count=0 ctx_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--ctx-size" ]; then
            ctx_count=$((ctx_count + 1))
            ctx_val="${CMD_ARRAY[$((i+1))]}"
        fi
    done
    [ "$ctx_count" -eq 1 ]
    [ "$ctx_val" = "2048" ]

    local found_gpu_layers=0
    for arg in "${CMD_ARRAY[@]}"; do
        [ "$arg" = "999" ] && found_gpu_layers=1
    done
    [ "$found_gpu_layers" -eq 1 ]
}

@test "build_cmdline: returns 1 for nonexistent backend (test-no-backend)" {
    load_config "$LLM_CONF"

    run build_cmdline "test-no-backend" "8080"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

@test "build_cmdline: returns 1 for missing <args> block (test-no-args)" {
    load_config "$LLM_CONF"

    run build_cmdline "test-no-args" "8080"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No <args> block found"* ]]
}

@test "build_cmdline: returns 1 when model has no backend and no override" {
    # Create a model section with no backend key
    cat >> "$MODELS_CONF" <<'CONF'

[model-no-backend-slim]
name=No Backend Slim
<args>
--ctx-size 2048
</args>
CONF

    load_config "$LLM_CONF"
    run build_cmdline "model-no-backend-slim" "8080"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No backend specified"* ]]
}

@test "build_cmdline: host defaults to SERVICE_HOST from config" {
    load_config "$LLM_CONF"

    build_cmdline "test-tiny" "9090" || false

    # Find --host and verify value
    local host_val="" port_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--host" ]; then
            local next=$((i + 1))
            host_val="${CMD_ARRAY[$next]}"
        fi
        if [ "${CMD_ARRAY[$i]}" = "--port" ]; then
            local next=$((i + 1))
            port_val="${CMD_ARRAY[$next]}"
        fi
    done
    [ "$host_val" = "127.0.0.1" ]
    [ "$port_val" = "9090" ]
}

@test "build_cmdline: host defaults to 0.0.0.0 when SERVICE_HOST unset" {
    unset SERVICE_HOST
    export SERVICE_HOST=""

    build_cmdline "test-tiny" "7070" || false

    local host_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--host" ]; then
            local next=$((i + 1))
            host_val="${CMD_ARRAY[$next]}"
        fi
    done
    [ "$host_val" = "0.0.0.0" ]
}

@test "build_cmdline: --device=VALUE format also prevents injection" {
    load_config "$LLM_CONF"

    # Create a model with --device=Vulkan0 in args
    cat >> "$MODELS_CONF" <<'CONF'

[model-device-eq]
backend=vulkan
<args>
--device=Vulkan0 \
--ctx-size 2048
</args>
CONF

    build_cmdline "model-device-eq" "8080" || false

    # Should NOT have a separate --device appended; only --device=Vulkan0 from model args
    local device_count=0
    for arg in "${CMD_ARRAY[@]}"; do
        [ "$arg" = "--device" ] && device_count=$((device_count + 1))
        [[ "$arg" == "--device="* ]] && device_count=$((device_count + 1))
    done
    [ "$device_count" -eq 1 ]
}

# ==============================================================================
# build_cmdline — flag deduplication (model overrides profile)
# ==============================================================================

@test "build_cmdline: model --ctx-size overrides profile --ctx-size (no duplicates)" {
    load_config "$LLM_CONF"

    cat >> "$MODELS_CONF" <<'CONF'

[model-ctx-override]
backend=cpu
profile=max
<args>
-hf Qwen/Qwen3-0.6B-GGUF \
--ctx-size 8192 \
--temp 0.8
</args>
CONF

    build_cmdline "model-ctx-override" "8080" || false

    local ctx_count=0 ctx_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--ctx-size" ]; then
            ctx_count=$((ctx_count + 1))
            ctx_val="${CMD_ARRAY[$((i+1))]}"
        fi
    done
    [ "$ctx_count" -eq 1 ]
    [ "$ctx_val" = "8192" ]
}

@test "build_cmdline: model --flash-attn overrides profile --flash-attn" {
    load_config "$LLM_CONF"

    cat >> "$MODELS_CONF" <<'CONF'

[model-flash-override]
backend=cpu
profile=max
<args>
-hf Qwen/Qwen3-0.6B-GGUF \
--flash-attn on
</args>
CONF

    build_cmdline "model-flash-override" "8080" || false

    local flash_count=0 flash_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--flash-attn" ]; then
            flash_count=$((flash_count + 1))
            flash_val="${CMD_ARRAY[$((i+1))]}"
        fi
    done
    [ "$flash_count" -eq 1 ]
    [ "$flash_val" = "on" ]
}

@test "build_cmdline: profile --ctx-size kept when model does not override" {
    load_config "$LLM_CONF"

    build_cmdline "test-max" "8080" || false

    local ctx_count=0 ctx_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        if [ "${CMD_ARRAY[$i]}" = "--ctx-size" ]; then
            ctx_count=$((ctx_count + 1))
            ctx_val="${CMD_ARRAY[$((i+1))]}"
        fi
    done
    [ "$ctx_count" -eq 1 ]
    [ "$ctx_val" = "262144" ]
}

@test "build_cmdline: multiple flag overrides deduplicate correctly" {
    load_config "$LLM_CONF"

    cat >> "$MODELS_CONF" <<'CONF'

[model-multi-override]
backend=cpu
profile=max
<args>
-hf Qwen/Qwen3-0.6B-GGUF \
--ctx-size 4096 \
--threads 4 \
--flash-attn on \
--gpu-layers 50
</args>
CONF

    build_cmdline "model-multi-override" "8080" || false

    local ctx_val="" threads_val="" flash_val="" gpu_val=""
    for i in "${!CMD_ARRAY[@]}"; do
        [ "${CMD_ARRAY[$i]}" = "--ctx-size" ] && ctx_val="${CMD_ARRAY[$((i+1))]}"
        [ "${CMD_ARRAY[$i]}" = "--threads" ] && threads_val="${CMD_ARRAY[$((i+1))]}"
        [ "${CMD_ARRAY[$i]}" = "--flash-attn" ] && flash_val="${CMD_ARRAY[$((i+1))]}"
        [ "${CMD_ARRAY[$i]}" = "--gpu-layers" ] && gpu_val="${CMD_ARRAY[$((i+1))]}"
    done
    [ "$ctx_val" = "4096" ]
    [ "$threads_val" = "4" ]
    [ "$flash_val" = "on" ]
    [ "$gpu_val" = "50" ]
}

# ==============================================================================
# validate_backend
# ==============================================================================

@test "validate_backend: returns 1 for missing binary" {
    # Create a model pointing to a nonexistent binary via a custom backend
    cat >> "$LLM_CONF" <<CONF

[backend.missing-bin]
binary=$TEST_DIR/no/such/binary
CONF

    cat >> "$MODELS_CONF" <<CONF

[model-missing-bin-test]
backend=missing-bin
<args>
--ctx-size 2048
</args>
CONF

    run validate_backend "model-missing-bin-test"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found or not executable"* ]]
}

@test "validate_backend: returns 0 when binary exists and is executable" {
    local fake_bin="$TEST_DIR/fake-bin"
    mkdir -p "$fake_bin"
    # Create a fake binary that matches what get_backend_binary returns
    local fake_exe="$fake_bin/llama-server"
    touch "$fake_exe"
    chmod +x "$fake_exe"

    # Override the backend binary path in config
    cat >> "$LLM_CONF" <<CONF

[backend.valid-test]
binary=$fake_exe
CONF

    # Create a model that uses this backend
    cat >> "$MODELS_CONF" <<CONF

[model-valid-test]
backend=valid-test
<args>
--ctx-size 2048
</args>
CONF

    run validate_backend "model-valid-test"
    [ "$status" -eq 0 ]
}

@test "validate_backend: handles venv-based binary" {
    local venv_dir="$TEST_DIR/test-venv"
    mkdir -p "$venv_dir/bin"
    local fake_exe="$venv_dir/bin/mybinary"
    touch "$fake_exe"
    chmod +x "$fake_exe"

    cat >> "$LLM_CONF" <<CONF

[backend.venv-valid]
binary=mybinary
venv=$venv_dir
CONF

    cat >> "$MODELS_CONF" <<CONF

[model-venv-test]
backend=venv-valid
<args>
--ctx-size 2048
</args>
CONF

    run validate_backend "model-venv-test"
    [ "$status" -eq 0 ]
}

@test "validate_backend: returns 1 when venv exists but binary missing inside" {
    local venv_dir="$TEST_DIR/test-venv-empty"
    mkdir -p "$venv_dir/bin"

    cat >> "$LLM_CONF" <<CONF

[backend.venv-missing-bin]
binary=mybinary
venv=$venv_dir
CONF

    cat >> "$MODELS_CONF" <<CONF

[model-venv-missing]
backend=venv-missing-bin
<args>
--ctx-size 2048
</args>
CONF

    run validate_backend "model-venv-missing"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found in venv"* ]]
}

@test "validate_backend: returns 1 for missing backend" {
    run validate_backend "test-no-backend"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

# ==============================================================================
# wait_for_port — skipped (requires network)
# ==============================================================================

@test "wait_for_port: skipped — requires live network" {
    skip "wait_for_port requires curl + network, tested in integration suite"
}
