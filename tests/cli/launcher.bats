#!/usr/bin/env bats
# launcher.bats — CLI logic tests for launcher.sh
# Covers: parse_model_args, list_models, prune_models, command dispatch

load '../bats-support/load'
load '../bats-assert/load'
load '../test_helper'

# test_helper computes PROJECT_DIR one level up from BATS_TEST_FILENAME,
# which works for tests/*.bats but yields tests/ instead of the project root
# for tests/cli/*.bats. Recompute: two levels up from tests/cli/.
PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$PROJECT_DIR/tests/fixtures"
BATS_BIN="$PROJECT_DIR/tests/bats/bin/bats"

setup() {
    setup_test_env
    source_launcher

    # launcher.sh hardcodes LLM_DIR to its script dir on line 15,
    # and MODELS_CONF to $LLM_DIR/models.conf on line 35.
    # Re-override all paths back to the isolated test directory.
    LLM_DIR="$TEST_DIR"
    MODELS_CONF="$TEST_DIR/models.conf"
    LLM_CONF="$TEST_DIR/llm.conf"
    CURRENT_MODEL_FILE="$TEST_DIR/current_model"
    INSTANCES_DIR="$TEST_DIR/instances"
    LOGS_DIR="$TEST_DIR/logs"
    mkdir -p "$INSTANCES_DIR" "$LOGS_DIR"

    # Reset parser globals between tests
    MODEL_ID=""
    RUNTIME_BACKEND=""
    RUNTIME_PROFILE=""
}

teardown() {
    cleanup_test_env
}

# Helper: write a prune-oriented models.conf with controlled valid/invalid entries
_write_prune_fixtures() {
    mkdir -p "$TEST_DIR/models"
    touch "$TEST_DIR/models/valid.gguf"

    cat > "$MODELS_CONF" << EOF
[valid-model]
name="Valid Model"
description="Has valid backend and existing model file"
backend=cpu
<args>
-m $TEST_DIR/models/valid.gguf
</args>

[bad-backend]
name="Bad Backend"
description="References a backend not defined in llm.conf"
backend=nonexistent
<args>
-m $TEST_DIR/models/valid.gguf
</args>

[missing-path]
name="Missing Path"
description="Points to a file that does not exist"
backend=cpu
<args>
-m $TEST_DIR/models/no_such_file.gguf
</args>

[no-path]
name="No Path"
description="Args contain only flags, no model path"
backend=cpu
<args>
--ctx-size 2048
--threads 2
</args>

[profile.max]
<args>
--threads 2
</args>
EOF
}

# ============================================================================
# parse_model_args
# ============================================================================

@test "parse_model_args: model only — sets MODEL_ID, no backend or profile" {
    parse_model_args "mymodel"
    [ "$?" -eq 0 ]
    [ "$MODEL_ID" = "mymodel" ]
    [ -z "$RUNTIME_BACKEND" ]
    [ -z "$RUNTIME_PROFILE" ]
}

@test "parse_model_args: model + known backend — sets MODEL_ID and RUNTIME_BACKEND" {
    parse_model_args "mymodel" "cuda"
    [ "$?" -eq 0 ]
    [ "$MODEL_ID" = "mymodel" ]
    [ "$RUNTIME_BACKEND" = "cuda" ]
    [ -z "$RUNTIME_PROFILE" ]
}

@test "parse_model_args: model + known profile — sets MODEL_ID and RUNTIME_PROFILE" {
    parse_model_args "mymodel" "max"
    [ "$?" -eq 0 ]
    [ "$MODEL_ID" = "mymodel" ]
    [ -z "$RUNTIME_BACKEND" ]
    [ "$RUNTIME_PROFILE" = "max" ]
}

@test "parse_model_args: model + backend + profile (order: backend then profile)" {
    parse_model_args "mymodel" "cuda" "max"
    [ "$?" -eq 0 ]
    [ "$MODEL_ID" = "mymodel" ]
    [ "$RUNTIME_BACKEND" = "cuda" ]
    [ "$RUNTIME_PROFILE" = "max" ]
}

@test "parse_model_args: model + profile + backend (reversed order)" {
    parse_model_args "mymodel" "max" "cuda"
    [ "$?" -eq 0 ]
    [ "$MODEL_ID" = "mymodel" ]
    [ "$RUNTIME_BACKEND" = "cuda" ]
    [ "$RUNTIME_PROFILE" = "max" ]
}

@test "parse_model_args: unknown arg — returns 1 with error message" {
    run parse_model_args "mymodel" "notabackend"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a known backend or profile"* ]]
}

@test "parse_model_args: ambiguous name (in both backends and profiles) — returns 1" {
    # "cpu" is a known backend from llm.conf.
    # Write a models.conf that also defines [profile.cpu].
    cat > "$MODELS_CONF" << 'EOF'
[profile.cpu]
<args>
--threads 2
</args>
EOF
    run parse_model_args "mymodel" "cpu"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ambiguous"* ]]
}

@test "parse_model_args: stops at --flag, remaining args ignored" {
    parse_model_args "mymodel" "--port" "8080" "cuda"
    [ "$?" -eq 0 ]
    [ "$MODEL_ID" = "mymodel" ]
    [ -z "$RUNTIME_BACKEND" ]
    [ -z "$RUNTIME_PROFILE" ]
}

@test "parse_model_args: no args — returns 1 with error" {
    run parse_model_args
    [ "$status" -eq 1 ]
    [[ "$output" == *"model name required"* ]]
}

# ============================================================================
# list_models
# ============================================================================

@test "list_models: lists all non-profile model names from fixture" {
    run list_models
    [ "$status" -eq 0 ]
    [[ "$output" == *"test-tiny"* ]]
    [[ "$output" == *"test-max"* ]]
    [[ "$output" == *"test-device-override"* ]]
    [[ "$output" == *"test-no-backend"* ]]
    [[ "$output" == *"test-no-args"* ]]
}

@test "list_models: skips profile.* sections" {
    run list_models
    # Profile section names must not appear as model entries
    [[ "$output" != *"profile.max"* ]]
    [[ "$output" != *"profile.fitmax"* ]]
    [[ "$output" != *"profile.high-parallel"* ]]
}

@test "list_models: shows [CURRENT] indicator when current_model matches" {
    echo "test-tiny|cpu|" > "$CURRENT_MODEL_FILE"
    run list_models
    [ "$status" -eq 0 ]
    [[ "$output" == *"[CURRENT]"* ]]
}

@test "list_models: handles empty models.conf gracefully" {
    : > "$MODELS_CONF"
    run list_models
    [ "$status" -eq 0 ]
    [[ "$output" == *"Available Models"* ]]
    [[ "$output" != *"test-tiny"* ]]
}

# ============================================================================
# prune_models
# ============================================================================

@test "prune_models: dry run reports invalid models without modifying file" {
    _write_prune_fixtures
    local content_before
    content_before=$(cat "$MODELS_CONF")

    run prune_models
    [ "$status" -eq 0 ]

    # Should mention invalid entries
    [[ "$output" == *"bad-backend"* ]]
    [[ "$output" == *"missing-path"* ]]
    [[ "$output" == *"no-path"* ]]
    # Should indicate dry run
    [[ "$output" == *"Dry run"* ]]

    # File must be unchanged
    local content_after
    content_after=$(cat "$MODELS_CONF")
    [ "$content_before" = "$content_after" ]
}

@test "prune_models: --force removes invalid models and creates backup" {
    _write_prune_fixtures

    run prune_models --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pruned"* ]]

    # Backup file must exist with original content
    [ -f "${MODELS_CONF}.bak" ]

    # Remaining file should retain valid-model and profile, lose invalid entries
    local remaining
    remaining=$(cat "$MODELS_CONF")
    [[ "$remaining" == *"valid-model"* ]]
    [[ "$remaining" != *"bad-backend"* ]]
    [[ "$remaining" != *"missing-path"* ]]
    [[ "$remaining" != *"no-path"* ]]
    [[ "$remaining" == *"profile.max"* ]]
}

@test "prune_models: skips profile.* sections — does not validate profiles as models" {
    _write_prune_fixtures

    run prune_models
    [ "$status" -eq 0 ]
    # profile.max must not appear in the prune output as an invalid entry
    [[ "$output" != *"profile.max"*"not found"* ]]
    [[ "$output" != *"profile.max"*"no backend"* ]]
}

@test "prune_models: detects model with nonexistent backend" {
    _write_prune_fixtures

    run prune_models
    [[ "$output" == *"bad-backend"* ]]
    [[ "$output" == *"backend 'nonexistent' not found"* ]]
}

@test "prune_models: detects model with nonexistent model path" {
    _write_prune_fixtures

    run prune_models
    [[ "$output" == *"missing-path"* ]]
    [[ "$output" == *"model path not found"* ]]
}

# ============================================================================
# Command dispatch (case statement — tested via subprocess)
# ============================================================================

@test "dispatch: list calls list_models" {
    run "$PROJECT_DIR/launcher.sh" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Available Models"* ]]
}

@test "dispatch: help shows usage" {
    run "$PROJECT_DIR/launcher.sh" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"LLM Launcher"* ]]
    [[ "$output" == *"Usage: llm"* ]]
}

@test "dispatch: --help shows usage" {
    run "$PROJECT_DIR/launcher.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"LLM Launcher"* ]]
}

@test "dispatch: -h shows usage" {
    run "$PROJECT_DIR/launcher.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"LLM Launcher"* ]]
}

@test "dispatch: unknown command prints error and exits 1" {
    run "$PROJECT_DIR/launcher.sh" boguscommand
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command: boguscommand"* ]]
}
