#!/bin/bash
# test_helper.bash — Shared setup/teardown for llm-manager bats tests
#
# Sourced by each test file via: load '../test_helper'
#
# Provides:
#   - TEST_DIR:      isolated temp directory per test
#   - FIXTURES_DIR:  path to test fixtures (configs)
#   - PROJECT_DIR:   path to the project root
#   - source_lib():  sources lib.sh with test environment
#   - source_launcher(): sources launcher.sh with test environment
#   - cleanup_test_env(): removes TEST_DIR

PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$PROJECT_DIR/tests/fixtures"
BATS_BIN="$PROJECT_DIR/tests/bats/bin/bats"

setup_test_env() {
    TEST_DIR="$(mktemp -d)"
    export LLM_DIR="$TEST_DIR"
    export LLM_CONF="$TEST_DIR/llm.conf"
    export MODELS_CONF="$TEST_DIR/models.conf"
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    cp "$FIXTURES_DIR/llm.conf" "$LLM_CONF"
    cp "$FIXTURES_DIR/models.conf" "$MODELS_CONF"
    mkdir -p "$TEST_DIR"/{models,logs,instances}
}

source_lib() {
    if [ -z "${LLM_DIR:-}" ]; then
        echo "setup_test_env must be called before source_lib" >&2
        return 1
    fi
    # shellcheck source=../lib.sh
    source "$PROJECT_DIR/lib.sh"
}

source_launcher() {
    export LLM_DIR
    export LLM_CONF
    set +e
    # shellcheck source=../launcher.sh
    source "$PROJECT_DIR/launcher.sh"
}

cleanup_test_env() {
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
