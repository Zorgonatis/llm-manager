#!/bin/bash
# lib.sh - Shared functions for launcher.sh and service-wrapper.sh
# Must be sourced after LLM_DIR is set.

if [ -z "${LLM_DIR:-}" ]; then
    echo "lib.sh: LLM_DIR must be set before sourcing" >&2
    exit 1
fi

# Shared constants
LOG_ROTATE_COUNT=5

# Trim leading/trailing whitespace (pure bash, no xargs)
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# Rotate a log file, keeping up to LOG_ROTATE_COUNT rotated copies
# Usage: rotate_log <file> [count]
rotate_log() {
    local log_file="$1"
    local count="${2:-$LOG_ROTATE_COUNT}"

    for i in $(seq $((count-1)) -1 1); do
        [ -f "${log_file}.$i" ] && mv "${log_file}.$i" "${log_file}.$((i+1))"
    done
    [ -f "$log_file" ] && mv "$log_file" "${log_file}.1" || true
}

# Load infrastructure config from llm.conf (top-level key=value only)
# Backend sections are handled separately by get_config_from.
# Top-level config must come before any [section] headers.
load_config() {
    local conf_file="$1"

    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// /}" ]] && continue

        # Stop at first section header - rest is handled by get_config_from
        [[ "$key" =~ ^\[.*\]$ ]] && break

        key=$(trim "$key")
        value=$(trim "$value" | tr -d '"')

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

# Parse INI config from specified file (for metadata fields)
# Usage: get_config_from <file> <section> <key>
get_config_from() {
    local conf_file="$1"
    local section="$2"
    local key="$3"
    local in_section=0

    while IFS='=' read -r k v; do
        k=$(trim "$k")
        v=$(trim "$v" | tr -d '"')
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
    done < "$conf_file"
    return 1
}

# Parse INI config from models.conf (convenience wrapper)
get_config() {
    get_config_from "$MODELS_CONF" "$1" "$2"
}

# Get backend binary path from llm.conf
# Usage: get_backend_binary <backend_name>
get_backend_binary() {
    local backend_name="$1"
    local binary
    binary=$(get_config_from "$LLM_CONF" "backend.$backend_name" "binary")
    if [ -z "$binary" ]; then
        echo "Error: Backend '$backend_name' not found in $LLM_CONF" >&2
        return 1
    fi
    echo "$binary"
}

# Extract <backend_args>...</backend_args> block from a backend definition in llm.conf
# Usage: get_backend_args_block <backend_name>
get_backend_args_block() {
    local backend_name="$1"
    local in_section=0
    local in_args=0
    local args_content=""

    while IFS= read -r line; do
        # Check for section header
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [ "${BASH_REMATCH[1]}" = "backend.$backend_name" ]; then
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
            if [[ "$line" =~ ^[[:space:]]*\<backend_args\>[[:space:]]*$ ]]; then
                in_args=1
                continue
            fi
            # Check for args block end
            if [[ "$line" =~ ^[[:space:]]*\</backend_args\>[[:space:]]*$ ]]; then
                break
            fi
            # Collect args content
            if [ $in_args -eq 1 ]; then
                args_content="$args_content$line"$'\n'
            fi
        fi
    done < "$LLM_CONF"

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
    return 0  # No backend_args is valid (e.g., llama.cpp doesn't need them)
}

# Get backend venv path from llm.conf (if specified)
# Usage: get_backend_venv <backend_name>
get_backend_venv() {
    local backend_name="$1"
    get_config_from "$LLM_CONF" "backend.$backend_name" "venv"
}

# Get backend device from llm.conf (optional GPU device identifier)
# Usage: get_backend_device <backend_name>
get_backend_device() {
    local backend_name="$1"
    get_config_from "$LLM_CONF" "backend.$backend_name" "device"
}

# Get backend extra args from llm.conf (generic --arg value pairs applied to all models)
# Usage: get_backend_extra_args <backend_name>
get_backend_extra_args() {
    local backend_name="$1"
    local in_section=0
    local in_extra=0
    local extra_content=""

    while IFS= read -r line; do
        # Check for section header
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [ "${BASH_REMATCH[1]}" = "backend.$backend_name" ]; then
                in_section=1
            else
                if [ $in_extra -eq 1 ]; then
                    break
                fi
                in_section=0
            fi
            continue
        fi

        if [ $in_section -eq 1 ]; then
            # Check for extra_args block start
            if [[ "$line" =~ ^[[:space:]]*\<extra_args\>[[:space:]]*$ ]]; then
                in_extra=1
                continue
            fi
            # Check for extra_args block end
            if [[ "$line" =~ ^[[:space:]]*\</extra_args\>[[:space:]]*$ ]]; then
                break
            fi
            # Collect extra content
            if [ $in_extra -eq 1 ]; then
                extra_content="$extra_content$line"$'\n'
            fi
        fi
    done < "$LLM_CONF"

    if [ -n "$extra_content" ]; then
        # Join continuation lines: space+backslash+newline → space
        extra_content=$(printf '%s\n' "$extra_content" | awk '{if(/\\$/) {printf "%s ", substr($0,1,length($0)-1)} else print}')
        # Expand $HOME and ~
        extra_content="${extra_content//\$HOME/$HOME}"
        extra_content="${extra_content//\~/$HOME}"
        # Trim whitespace and collapse multiple spaces
        extra_content=$(printf '%s' "$extra_content" | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$extra_content"
        return 0
    fi
    return 0  # No extra_args is valid
}

# Activate backend's venv if specified (modifies PATH and sets VIRTUAL_ENV)
# Usage: activate_backend_venv <backend_name>
activate_backend_venv() {
    local backend_name="$1"
    local venv_path
    venv_path=$(get_backend_venv "$backend_name") || true

    if [ -n "$venv_path" ] && [ -d "$venv_path" ]; then
        export VIRTUAL_ENV="$venv_path"
        export PATH="$venv_path/bin:$PATH"
    fi
    return 0
}

# Extract <args>...</args> block from a section in models.conf
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

# Get profile args from models.conf (reuses get_args_block for profile.<name> sections)
# Usage: get_profile_args <profile_name>
get_profile_args() {
    local profile_name="$1"
    get_args_block "profile.$profile_name"
}

# Parse current_model file: returns "model_id|backend|profile"
# Backwards compatible: old format (just model_id) becomes "model_id||"
# Usage: read_current_model <file>
read_current_model() {
    local file="$1"
    if [ ! -f "$file" ]; then return 1; fi
    local content
    content=$(cat "$file")
    if [[ "$content" == *"|"* ]]; then
        echo "$content"
    else
        echo "$content||"
    fi
}

# Global command array for proper arg handling
CMD_ARRAY=()

# Build command array from config (no eval — safe word-splitting)
# Command structure: binary + backend_args + profile_args + model_args + extra_args + --host --port + [--device]
# Usage: build_cmdline <model_id> <port> [backend_override] [profile_override]
build_cmdline() {
    local model_id="$1"
    local port="$2"
    local runtime_backend="${3:-}"
    local runtime_profile="${4:-}"

    # Resolve backend: runtime override > model config default
    local backend binary
    backend="${runtime_backend:-$(get_config "$model_id" "backend")}"
    if [ -z "$backend" ]; then
        echo "Error: No backend specified for model '$model_id'" >&2
        return 1
    fi
    binary=$(get_backend_binary "$backend") || return 1

    CMD_ARRAY=("$binary")

    # Add backend_args (e.g., "serve" for vLLM)
    local backend_args
    backend_args=$(get_backend_args_block "$backend")
    if [ -n "$backend_args" ]; then
        local arg
        while IFS= read -r arg; do
            [ -n "$arg" ] && CMD_ARRAY+=("$arg")
        done < <(printf '%s\n' $backend_args)
    fi

    # Add profile args (if profile specified: runtime override > model config)
    local profile="${runtime_profile:-$(get_config "$model_id" "profile")}"
    if [ -n "$profile" ]; then
        local profile_args
        profile_args=$(get_profile_args "$profile")
        if [ -n "$profile_args" ]; then
            local arg
            while IFS= read -r arg; do
                [ -n "$arg" ] && CMD_ARRAY+=("$arg")
            done < <(printf '%s\n' $profile_args)
        fi
    fi

    # Add model args from <args> block
    local args
    args=$(get_args_block "$model_id")
    if [ -z "$args" ]; then
        echo "Error: No <args> block found for model '$model_id'" >&2
        return 1
    fi

    # Word-split args on whitespace into the array.
    # Safe: get_args_block already expanded $HOME/~, leaving only
    # --flags, values, and bare flags like -rtr
    local arg
    while IFS= read -r arg; do
        [ -n "$arg" ] && CMD_ARRAY+=("$arg")
    done < <(printf '%s\n' $args)

    # Add extra_args from backend config (if any) - placed AFTER model args
    # This is required for vLLM where --served-model-name must come after model path
    local extra_args
    extra_args=$(get_backend_extra_args "$backend")
    if [ -n "$extra_args" ]; then
        local arg
        while IFS= read -r arg; do
            [ -n "$arg" ] && CMD_ARRAY+=("$arg")
        done < <(printf '%s\n' $extra_args)
    fi

    # use configured host or default
    local host="${SERVICE_HOST:-0.0.0.0}"
    CMD_ARRAY+=(--host "$host" --port "$port")

    # Inject --device from backend config if not already present in merged args
    local has_device=0 arg
    for arg in "${CMD_ARRAY[@]}"; do
        if [ "$arg" = "--device" ] || [[ "$arg" == --device=* ]]; then
            has_device=1
            break
        fi
    done
    if [ $has_device -eq 0 ]; then
        local device
        device=$(get_backend_device "$backend")
        if [ -n "$device" ]; then
            CMD_ARRAY+=(--device "$device")
        fi
    fi

    # Deduplicate flags: last occurrence wins (model overrides profile overrides backend).
    # Parse forward: positional args keep their order, --flags use last-wins via assoc array.
    local -a positional=()
    local -A flag_order=()
    local -A flag_values=()
    local -A flag_has_value=()
    local order_counter=0

    local i=0
    local len=${#CMD_ARRAY[@]}
    while [ $i -lt $len ]; do
        local item="${CMD_ARRAY[$i]}"

        if [[ "$item" =~ ^--([^=[:space:]]+)=(.*)$ ]]; then
            local fname="${BASH_REMATCH[1]}"
            flag_values["$fname"]="${BASH_REMATCH[2]}"
            flag_has_value["$fname"]="eq"
            flag_order["$fname"]=$((order_counter++))
            i=$((i + 1))
        elif [[ "$item" =~ ^--([^=[:space:]]+)$ ]]; then
            local fname="${BASH_REMATCH[1]}"
            if [ $((i+1)) -lt $len ] && [[ ! "${CMD_ARRAY[$((i+1))]}" =~ ^-- ]]; then
                flag_values["$fname"]="${CMD_ARRAY[$((i+1))]}"
                flag_has_value["$fname"]="sep"
                flag_order["$fname"]=$((order_counter++))
                i=$((i + 2))
            else
                flag_values["$fname"]=""
                flag_has_value["$fname"]="bare"
                flag_order["$fname"]=$((order_counter++))
                i=$((i + 1))
            fi
        else
            positional+=("$order_counter:$item")
            order_counter=$((order_counter + 1))
            i=$((i + 1))
        fi
    done

    # Reconstruct: merge positional and flags, sort by original order (last-write index)
    local -a entries=()
    local idx
    for idx in "${!flag_order[@]}"; do
        local order="${flag_order[$idx]}"
        local entry="${order}:flag:${idx}"
        entries+=("$entry")
    done
    for idx in "${positional[@]}"; do
        entries+=("$idx")
    done

    # Sort entries by order number
    IFS=$'\n' sorted=($(printf '%s\n' "${entries[@]}" | sort -t: -k1,1n)); unset IFS

    CMD_ARRAY=()
    for entry in "${sorted[@]}"; do
        local order="${entry%%:*}"
        local rest="${entry#*:}"
        if [[ "$rest" == flag:* ]]; then
            local fname="${rest#flag:}"
            case "${flag_has_value[$fname]}" in
                eq) CMD_ARRAY+=("--${fname}=${flag_values[$fname]}") ;;
                sep) CMD_ARRAY+=("--${fname}" "${flag_values[$fname]}") ;;
                bare) CMD_ARRAY+=("--${fname}") ;;
            esac
        else
            CMD_ARRAY+=("$rest")
        fi
    done
}

# Validate backend binary exists
# Usage: validate_backend <model_id> [backend_override]
validate_backend() {
    local model_id="$1"
    local runtime_backend="${2:-}"
    local backend binary venv_path

    backend="${runtime_backend:-$(get_config "$model_id" "backend")}"
    if [ -z "$backend" ]; then
        echo "Error: No backend specified for model '$model_id'" >&2
        return 1
    fi
    binary=$(get_backend_binary "$backend") || return 1

    # Check if backend has a venv - binary may be in venv's bin
    venv_path=$(get_backend_venv "$backend")
    if [ -n "$venv_path" ] && [ -d "$venv_path" ]; then
        # Binary is relative to venv
        if [ -x "$venv_path/bin/$binary" ]; then
            return 0
        fi
        # Or it's already a full path
        if [ -x "$binary" ]; then
            return 0
        fi
        echo "Error: Backend binary not found in venv: $venv_path/bin/$binary" >&2
        return 1
    fi

    # No venv - check binary directly
    if [ ! -x "$binary" ]; then
        echo "Error: Backend binary not found or not executable: $binary" >&2
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
