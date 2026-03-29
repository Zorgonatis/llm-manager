#!/bin/bash
# lib.sh - Shared functions for launcher.sh and service-wrapper.sh
# Must be sourced after LLM_DIR is set.

if [ -z "${LLM_DIR:-}" ]; then
    echo "lib.sh: LLM_DIR must be set before sourcing" >&2
    exit 1
fi

# Shared constants
LOG_ROTATE_COUNT=5

# Rotate a log file, keeping up to LOG_ROTATE_COUNT rotated copies
# Usage: rotate_log <file> [count]
rotate_log() {
    local log_file="$1"
    local count="${2:-$LOG_ROTATE_COUNT}"

    for i in $(seq $((count-1)) -1 1); do
        [ -f "${log_file}.$i" ] && mv "${log_file}.$i" "${log_file}.$((i+1))"
    done
    [ -f "$log_file" ] && mv "$log_file" "${log_file}.1"
}

# Load infrastructure config from llm.conf
load_config() {
    local conf_file="$1"

    # Read config file and export variables with expansion
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue

        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs | tr -d '"')

        # Expand variables using safe string substitution (no eval)
        value="${value//\$llm_dir/$LLM_DIR}"
        value="${value//\$\{llm_dir\}/$LLM_DIR}"
        value="${value//\$HOME/$HOME}"
        value="${value/#\~/$HOME}"

        # Export as uppercase variable
        local key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]')
        export "$key_upper=$value"
    done < "$conf_file"
}

# Parse INI config (for metadata fields)
get_config() {
    local section="$1"
    local key="$2"
    local in_section=0

    while IFS='=' read -r k v; do
        k=$(echo "$k" | xargs)
        v=$(echo "$v" | xargs | tr -d '"')
        # Expand $HOME and ~
        v="${v//\$HOME/$HOME}"
        v="${v/#\~/$HOME}"

        if [[ "$k" =~ ^\[(.*)\]$ ]]; then
            local section_name="${BASH_REMATCH[1]}"
            if [ "$section_name" = "$section" ]; then
                in_section=1
            else
                in_section=0
            fi
        elif [ $in_section -eq 1 ] && [ "$k" = "$key" ]; then
            echo "$v"
            return
        fi
    done < "$MODELS_CONF"
    return 1
}

# Extract <args>...</args> block from a section
get_args_block() {
    local section="$1"
    local in_section=0
    local in_args=0
    local args_content=""

    while IFS= read -r line; do
        # Check for section header
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [ "${BASH_REMATCH[1]}" = "$section" ]; then
                in_section=1
            else
                if [ $in_args -eq 1 ]; then
                    break
                fi
                in_section=0
            fi
            continue
        fi

        if [ $in_section -eq 1 ]; then
            # Check for args block start
            if [[ "$line" =~ ^[[:space:]]*\<args\>[[:space:]]*$ ]]; then
                in_args=1
                continue
            fi
            # Check for args block end
            if [[ "$line" =~ ^[[:space:]]*\</args\>[[:space:]]*$ ]]; then
                break
            fi
            # Collect args content
            if [ $in_args -eq 1 ]; then
                args_content="$args_content$line"$'\n'
            fi
        fi
    done < "$MODELS_CONF"

    if [ -n "$args_content" ]; then
        # Join continuation lines: space+backslash+newline → space
        args_content=$(printf '%s\n' "$args_content" | awk '{if(/\\$/) {printf "%s ", substr($0,1,length($0)-1)} else print}')
        # Expand $HOME and ~
        args_content="${args_content//\$HOME/$HOME}"
        args_content="${args_content//\~/$HOME}"
        # Trim whitespace and collapse multiple spaces
        args_content=$(printf '%s' "$args_content" | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$args_content"
        return 0
    fi
    return 1
}

# Global command array for proper arg handling
CMD_ARRAY=()

# Build command array from config (no eval — safe word-splitting)
build_cmdline() {
    local model_id="$1"
    local port="$2"

    local build
    build=$(get_config "$model_id" "build")
    local model
    model=$(get_config "$model_id" "model")

    CMD_ARRAY=("$build/bin/llama-server" -m "$model")

    local args
    args=$(get_args_block "$model_id")
    if [ -z "$args" ]; then
        echo "Error: No <args> block found for model '$model_id'" >&2
        return 1
    fi

    # Word-split args on whitespace into the array.
    # Safe: get_args_block already expanded $HOME/~, leaving only
    # --flags, values, and bare flags like -rtr.
    local arg
    while IFS= read -r arg; do
        [ -n "$arg" ] && CMD_ARRAY+=("$arg")
    done < <(printf '%s\n' $args)

    CMD_ARRAY+=(--host 0.0.0.0 --port "$port")
}

# Validate model build and file paths exist
validate_model_paths() {
    local model_id="$1"
    local build model

    build=$(get_config "$model_id" "build")
    model=$(get_config "$model_id" "model")

    if [ ! -x "$build/bin/llama-server" ]; then
        echo "Error: llama-server not found or not executable: $build/bin/llama-server" >&2
        return 1
    fi
    if [ ! -f "$model" ]; then
        echo "Error: Model file not found: $model" >&2
        return 1
    fi
    return 0
}

# Wait for a port to respond (polls with curl)
# Usage: wait_for_port <port> [timeout_seconds]
wait_for_port() {
    local port="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while [ $elapsed -lt $((timeout * 2)) ]; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if curl -s "http://127.0.0.1:$port" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}
