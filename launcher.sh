#!/bin/bash
# LLM Launcher - Manage multiple llama.cpp models and builds
# Usage: llm [command] [model] [profile] [backend] [--flags]

# Determine script location (follow symlinks to find the real script dir)
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
LLM_DIR="$SCRIPT_DIR"

# Config location
LLM_CONF="${LLM_CONF:-$LLM_DIR/llm.conf}"

# Source shared library
source "$LLM_DIR/lib.sh"

# Load config or use defaults
if [ -f "$LLM_CONF" ]; then
    load_config "$LLM_CONF"
fi

# Set defaults for any missing values
MODELS_DIR="${MODELS_DIR:-$LLM_DIR/models}"
SERVICE_PORT="${SERVICE_PORT:-4444}"
INSTANCE_PORT_START="${INSTANCE_PORT_START:-8081}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

# Config paths
MODELS_CONF="$LLM_DIR/models.conf"
LOGS_DIR="$LLM_DIR/logs"
INSTANCES_DIR="$LLM_DIR/instances"
CURRENT_MODEL_FILE="$LLM_DIR/current_model"
SERVICE_FILE="$LLM_DIR/llm.service"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Ensure instances directory exists
mkdir -p "$INSTANCES_DIR"

usage() {
    local svc_port="${SERVICE_PORT:-4444}"
    local inst_port="${INSTANCE_PORT_START:-8081}"

    echo "LLM Launcher - Manage llama.cpp models"
    echo ""
    echo "Usage: llm <command> [model] [profile] [backend] [--flags]"
    echo ""
    echo "Service Commands (port $svc_port, persistent):"
    echo "  serve <model> [profile] [backend]   Start/restart service on port $svc_port"
    echo "  restart <model> [profile] [backend] Restart service with new model"
    echo "  stop service                        Stop the systemd service"
    echo "  status                              Show service and instances status"
    echo "  logs                                Show service logs"
    echo "  enable                              Enable service on boot"
    echo "  disable                             Disable service on boot"
    echo ""
    echo "Instance Commands (additional instances):"
    echo "  start <model> [profile] [backend] [--port PORT]  Start instance (default: $inst_port)"
    echo "  stop [--port PORT]                                Stop instance(s) (default: all)"
    echo ""
    echo "Other Commands:"
    echo "  list            List available models"
    echo "  prune           Remove models with missing backend or file [--force]"
    echo "  help            This help"
    echo ""
    echo "Examples:"
    echo "  llm serve qwen-35b                          # Start with model defaults"
    echo "  llm serve qwen-35b rocm                     # Override backend"
    echo "  llm serve qwen-35b mem-tight                # Override profile"
    echo "  llm serve qwen-35b mem-tight rocm           # Override both"
    echo "  llm start glm-4.7 --port $((inst_port + 1))"
    echo "  llm stop                      # Stop all instances"
    echo "  llm stop --port $inst_port     # Stop instance on port $inst_port"
    echo "  llm stop service              # Stop the service"
    echo "  llm list"
}

# Install systemd service
install_service() {
    mkdir -p "$SYSTEMD_USER_DIR"
    cp "$SERVICE_FILE" "$SYSTEMD_USER_DIR/"
    systemctl --user daemon-reload
    echo -e "${GREEN}Systemd service installed${NC}"
}

# Ensure service is installed
ensure_service() {
    if [ ! -f "$SYSTEMD_USER_DIR/llm.service" ]; then
        install_service
    fi
}

# ==================== SMART POSITIONAL CLI PARSER ====================

# Parse positional args for serve/start: model [profile] [backend] [--flags...]
# Sets globals: MODEL_ID, RUNTIME_BACKEND, RUNTIME_PROFILE
parse_model_args() {
    local args=("$@")
    local positional=()

    # Separate positional args from --flags (stop at first --flag)
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            --*) break ;;
            *) positional+=("${args[$i]}"); i=$((i+1)) ;;
        esac
    done

    # First positional = model (required)
    if [ ${#positional[@]} -eq 0 ]; then
        echo "Error: model name required" >&2
        return 1
    fi
    MODEL_ID="${positional[0]}"

    # Build known sets from config files
    local -a known_backends=()
    local -a known_profiles=()

    # Parse llm.conf for [backend.X] sections
    if [ -f "$LLM_CONF" ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[backend\.(.*)\]$ ]]; then
                known_backends+=("${BASH_REMATCH[1]}")
            fi
        done < "$LLM_CONF"
    fi

    # Parse models.conf for [profile.X] sections
    if [ -f "$MODELS_CONF" ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[profile\.(.*)\]$ ]]; then
                known_profiles+=("${BASH_REMATCH[1]}")
            fi
        done < "$MODELS_CONF"
    fi

    # Resolve remaining positional args against known sets
    RUNTIME_BACKEND=""
    RUNTIME_PROFILE=""

    local arg
    for arg in "${positional[@]:1}"; do
        local is_backend=0 is_profile=0

        local b
        for b in "${known_backends[@]}"; do
            if [ "$arg" = "$b" ]; then
                is_backend=1
                break
            fi
        done

        local p
        for p in "${known_profiles[@]}"; do
            if [ "$arg" = "$p" ]; then
                is_profile=1
                break
            fi
        done

        if [ $is_backend -eq 1 ] && [ $is_profile -eq 1 ]; then
            echo "Error: '$arg' is ambiguous (matches both backend and profile)" >&2
            return 1
        elif [ $is_backend -eq 1 ]; then
            RUNTIME_BACKEND="$arg"
        elif [ $is_profile -eq 1 ]; then
            RUNTIME_PROFILE="$arg"
        else
            echo "Error: '$arg' is not a known backend or profile" >&2
            return 1
        fi
    done
}

# ==================== MODEL LISTING ====================

# Print a model entry for list_models
_print_model_entry() {
    local model_id="$1" name="$2" description="$3" backend="$4" profile="$5" current="$6"

    local status=""

    if [ -n "$backend" ]; then
        local binary
        binary=$(get_backend_binary "$backend" 2>/dev/null || true)
        if [ -n "$binary" ] && [ -x "$binary" ]; then
            status="${GREEN}✓${NC} default backend: $backend"
        else
            status="${YELLOW}⚠${NC} default backend: $backend (not found)"
        fi
    else
        status="${YELLOW}⚠${NC} no default backend"
    fi

    local current_indicator=""
    if [ "$model_id" = "$current" ]; then
        current_indicator="${BLUE}[CURRENT]${NC} "
    fi

    echo -e "  ${YELLOW}$model_id${NC} $current_indicator$status"
    [ -n "$profile" ] && echo -e "    profile: $profile"
    echo -e "    $name"
    echo -e "    $description"
    echo ""
}

# List models (single-pass parse, skips profile.* sections)
list_models() {
    echo -e "${BLUE}Available Models:${NC}"
    echo ""

    local current=""
    if [ -f "$CURRENT_MODEL_FILE" ]; then
        local current_parsed
        current_parsed=$(read_current_model "$CURRENT_MODEL_FILE") || true
        current="${current_parsed%%|*}"
    fi

    local section="" name="" description="" backend="" profile=""
    local in_args=0

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            # Print previous section (skip profile sections)
            if [ -n "$section" ] && [[ "$section" != profile.* ]]; then
                _print_model_entry "$section" "$name" "$description" "$backend" "$profile" "$current"
            fi
            section="${BASH_REMATCH[1]}"
            name="" description="" backend="" profile=""
            in_args=0
            continue
        fi

        # Skip content inside profile sections
        if [[ "$section" == profile.* ]]; then
            continue
        fi

        # Skip <args> block content
        if [[ "$line" =~ ^[[:space:]]*\<args\>[[:space:]]*$ ]]; then
            in_args=1
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*\</args\>[[:space:]]*$ ]]; then
            in_args=0
            continue
        fi
        [ "$in_args" -eq 1 ] && continue

        # Parse key=value
        if [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
            local key value
            key=$(trim "${BASH_REMATCH[1]}")
            value=$(trim "${BASH_REMATCH[2]}" | tr -d '"')
            value="${value/#\$HOME/$HOME}"
            value="${value/#\~/$HOME}"

            case "$key" in
                name) name="$value" ;;
                description) description="$value" ;;
                backend) backend="$value" ;;
                profile) profile="$value" ;;
            esac
        fi
    done < "$MODELS_CONF"

    # Print last section (skip profile sections)
    if [ -n "$section" ] && [[ "$section" != profile.* ]]; then
        _print_model_entry "$section" "$name" "$description" "$backend" "$profile" "$current"
    fi
}

get_current_model() {
    if [ -f "$CURRENT_MODEL_FILE" ]; then
        local content
        content=$(cat "$CURRENT_MODEL_FILE")
        # Return just the model_id (before first |)
        echo "${content%%|*}"
    fi
}

get_service_status() {
    systemctl --user is-enabled llm.service 2>/dev/null && echo "enabled" || echo "disabled"
    systemctl --user is-active llm.service 2>/dev/null && echo "active" || echo "inactive"
}

# ==================== SERVICE COMMANDS ====================

serve_model() {
    ensure_service
    parse_model_args "$@" || return 1

    local model_id="$MODEL_ID"
    local runtime_backend="$RUNTIME_BACKEND"
    local runtime_profile="$RUNTIME_PROFILE"

    # Validate model exists
    if ! grep -q "^\[$model_id\]" "$MODELS_CONF"; then
        echo -e "${RED}Error: Model '$model_id' not found${NC}"
        echo "Use 'llm list' to see available models"
        return 1
    fi

    # Resolve effective backend
    local backend="${runtime_backend:-$(get_config "$model_id" "backend")}"
    if [ -z "$backend" ]; then
        echo -e "${RED}Error: No backend specified for model '$model_id'${NC}"
        return 1
    fi

    if ! validate_backend "$model_id" "$backend"; then
        return 1
    fi

    # Save current model (extended format: model_id|backend|profile)
    echo "${model_id}|${runtime_backend}|${runtime_profile}" > "$CURRENT_MODEL_FILE"

    # Get model info
    local name=$(get_config "$model_id" "name")
    local profile="${runtime_profile:-$(get_config "$model_id" "profile")}"

    echo -e "${BLUE}Setting service model:${NC} $name"
    echo -e "Model ID: $model_id"
    echo -e "Backend: $backend"
    [ -n "$profile" ] && echo -e "Profile: $profile"
    echo -e "Port: $SERVICE_PORT"
    echo ""

    # Start or restart the service
    if systemctl --user is-active llm.service >/dev/null 2>&1; then
        echo "Restarting service..."
        systemctl --user restart llm.service
    else
        echo "Starting service..."
        systemctl --user start llm.service
    fi

    # Quick check if service is responding (model loading continues in background)
    if wait_for_port "$SERVICE_PORT" 5; then
        echo -e "${GREEN}Service started successfully${NC}"
        echo ""
        echo "Recent logs:"
        journalctl --user -u llm.service -n 20 --no-pager
    else
        echo -e "${YELLOW}Service not responding yet — model may still be loading${NC}"
        echo "  Check: llm logs"
    fi
}

stop_service() {
    ensure_service

    if systemctl --user is-active llm.service >/dev/null 2>&1; then
        echo -e "${YELLOW}Stopping service...${NC}"

        # Get the main PID before stopping
        local pid=$(systemctl --user show -p MainPID --value llm.service 2>/dev/null)

        # Send graceful shutdown signal
        systemctl --user stop llm.service

        # Wait for process to actually terminate (vLLM can take time)
        if [ -n "$pid" ] && [ "$pid" != "0" ]; then
            local i=0
            while [ $i -lt 30 ]; do  # 30 second timeout
                if ! ps -p "$pid" >/dev/null 2>&1; then
                    break
                fi
                sleep 1
                i=$((i + 1))
                printf "."
            done
            echo ""

            # Force kill if still running
            if ps -p "$pid" >/dev/null 2>&1; then
                echo -e "${YELLOW}Force killing stubborn process (PID: $pid)${NC}"
                kill -9 "$pid" 2>/dev/null
            fi
        fi

        echo -e "${GREEN}Service stopped${NC}"
    else
        echo -e "${YELLOW}Service not running${NC}"
    fi

    # Clear current model (safe during restart: serve_model recreates it synchronously)
    rm -f "$CURRENT_MODEL_FILE"
}

stop_all_instances() {
    local found=0
    for pid_file in "$INSTANCES_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            found=1
            local port=$(basename "$pid_file" .pid)
            local pid=$(cat "$pid_file")

            if ps -p "$pid" >/dev/null 2>&1; then
                echo -e "${YELLOW}Stopping instance on port $port (PID: $pid)...${NC}"
                kill "$pid"

                # Wait for graceful shutdown (up to 10 seconds)
                local i=0
                while [ $i -lt 10 ]; do
                    if ! ps -p "$pid" >/dev/null 2>&1; then
                        break
                    fi
                    sleep 1
                    i=$((i + 1))
                done

                # Force kill if still running
                if ps -p "$pid" >/dev/null 2>&1; then
                    echo -e "${YELLOW}Force killing instance on port $port${NC}"
                    kill -9 "$pid"
                fi
                rm -f "$pid_file"
            else
                # Stale PID file
                rm -f "$pid_file"
            fi
        fi
    done

    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}No instances running${NC}"
    else
        echo -e "${GREEN}All instances stopped${NC}"
    fi
}

restart_service() {
    stop_service
    sleep 2
    serve_model "$@"
}

show_service_status() {
    ensure_service

    local current_parsed
    current_parsed=$(read_current_model "$CURRENT_MODEL_FILE") || true
    local current="${current_parsed%%|*}"

    local enabled_status=$(get_service_status | head -1)
    local active_status=$(get_service_status | tail -1)

    echo -e "${BLUE}LLM Service (port $SERVICE_PORT):${NC}"

    if [ "$active_status" = "active" ]; then
        if [ -n "$current" ]; then
            local name=$(get_config "$current" "name" 2>/dev/null || echo "$current")
            local pid=$(systemctl --user show -p MainPID --value llm.service 2>/dev/null || echo "unknown")

            # Parse runtime overrides from current_model
            local cur_backend="" cur_profile=""
            IFS='|' read -r _ cur_backend cur_profile <<< "$current_parsed"
            local backend="${cur_backend:-$(get_config "$current" "backend")}"
            local profile="${cur_profile:-$(get_config "$current" "profile")}"

            echo -e "  ${GREEN}● running${NC} ${BLUE}$name${NC}"
            echo -e "     Backend: $backend"
            [ -n "$profile" ] && echo -e "     Profile: $profile"
            echo -e "     PID: $pid | $(get_process_info "$pid")"
        else
            echo -e "  ${GREEN}● running${NC} (no model info)"
        fi
    else
        echo -e "  ${YELLOW}○ stopped${NC} (boot: $enabled_status)"
        if [ -n "$current" ]; then
            echo -e "     Last: $current"
        fi
    fi
}

get_process_info() {
    local pid="$1"
    if [ -n "$pid" ] && [ "$pid" != "unknown" ] && ps -p "$pid" >/dev/null 2>&1; then
        local mem=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.1fGB", $1/1024/1024}')
        local elapsed=$(trim "$(ps -p "$pid" -o etime= 2>/dev/null)")
        echo "$mem | up $elapsed"
    fi
}

show_all_instances() {
    local found=0

    for pid_file in "$INSTANCES_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            found=1
            local port=$(basename "$pid_file" .pid)
            local pid=$(cat "$pid_file")

            if ps -p "$pid" >/dev/null 2>&1; then
                echo -e "  ${GREEN}● port $port${NC} $(get_process_info "$pid")"
            else
                # Stale PID file
                rm -f "$pid_file"
            fi
        fi
    done

    if [ $found -eq 0 ]; then
        echo -e "  ${YELLOW}no instances running${NC}"
    fi
}

show_service_logs() {
    ensure_service

    if systemctl --user is-active llm.service >/dev/null 2>&1; then
        journalctl --user -u llm.service -f
    else
        echo -e "${YELLOW}Service not running${NC}"
        echo ""
        echo "Showing recent logs:"
        journalctl --user -u llm.service -n 50 --no-pager
    fi
}

enable_service() {
    ensure_service
    systemctl --user enable llm.service
    echo -e "${GREEN}Service enabled on boot${NC}"
}

disable_service() {
    ensure_service
    systemctl --user disable llm.service
    echo -e "${YELLOW}Service disabled on boot${NC}"
}

# ==================== INSTANCE COMMANDS ====================

start_instance() {
    parse_model_args "$@" || return 1

    local model_id="$MODEL_ID"
    local runtime_backend="$RUNTIME_BACKEND"
    local runtime_profile="$RUNTIME_PROFILE"
    local port="${INSTANCE_PORT_START:-8081}"

    # Extract --port flag from args
    local args=("$@")
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            --port)
                port="${args[$((i+1))]}"
                i=$((i+2))
                ;;
            *)
                i=$((i+1))
                ;;
        esac
    done

    # Validate model exists
    if ! grep -q "^\[$model_id\]" "$MODELS_CONF"; then
        echo -e "${RED}Error: Model '$model_id' not found${NC}"
        echo "Use 'llm list' to see available models"
        return 1
    fi

    # Resolve effective backend
    local backend="${runtime_backend:-$(get_config "$model_id" "backend")}"
    if [ -z "$backend" ]; then
        echo -e "${RED}Error: No backend specified for model '$model_id'${NC}"
        return 1
    fi

    if ! validate_backend "$model_id" "$backend"; then
        return 1
    fi

    # Check if port already in use
    local pid_file="$INSTANCES_DIR/$port.pid"
    if [ -f "$pid_file" ]; then
        local existing_pid=$(cat "$pid_file")
        if ps -p "$existing_pid" >/dev/null 2>&1; then
            echo -e "${YELLOW}Instance already running on port $port (PID: $existing_pid)${NC}"
            return 1
        else
            # Stale PID file
            rm -f "$pid_file"
        fi
    fi

    # Get model info
    local name=$(get_config "$model_id" "name")
    local profile="${runtime_profile:-$(get_config "$model_id" "profile")}"

    echo -e "${BLUE}Starting instance:${NC} $name"
    echo -e "Model ID: $model_id"
    echo -e "Backend: $backend"
    [ -n "$profile" ] && echo -e "Profile: $profile"
    echo -e "Port: $port"
    echo ""

    # Build command
    build_cmdline "$model_id" "$port" "$backend" "$profile"

    # Create log file with rotation
    local log_file="$LOGS_DIR/instance-$port.log"
    mkdir -p "$LOGS_DIR"

    # Rotate instance logs
    rotate_log "$log_file"

    # Activate venv if backend requires it
    activate_backend_venv "$backend"

    # Start in background
    nohup "${CMD_ARRAY[@]}" >> "$log_file" 2>&1 &
    local pid=$!

    # Save PID
    echo "$pid" > "$pid_file"

    # Quick check if the process is alive (model loading continues in background)
    if wait_for_port "$port" 5; then
        echo -e "${GREEN}Instance started successfully${NC}"
        echo -e "  PID: $pid"
        echo -e "  Log: $log_file"
        echo ""
        echo "Recent logs:"
        tail -n 20 "$log_file"
    elif ! ps -p "$pid" >/dev/null 2>&1; then
        echo -e "${RED}Instance failed to start${NC}"
        echo ""
        echo "Logs:"
        cat "$log_file"
        rm -f "$pid_file"
        return 1
    else
        echo -e "${GREEN}Instance started (loading model in background)${NC}"
        echo -e "  PID: $pid"
        echo -e "  Log: $log_file"
    fi
}

stop_instance() {
    local port="${INSTANCE_PORT_START:-8081}"

    shift  # Remove "stop" command
    while [[ $# -gt 0 ]]; do
        case $1 in
            --port)
                port="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local pid_file="$INSTANCES_DIR/$port.pid"

    if [ ! -f "$pid_file" ]; then
        echo -e "${YELLOW}No instance running on port $port${NC}"
        return 1
    fi

    local pid=$(cat "$pid_file")

    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo -e "${YELLOW}Instance already stopped (stale PID file)${NC}"
        rm -f "$pid_file"
        return 0
    fi

    echo -e "${YELLOW}Stopping instance on port $port...${NC}"
    kill "$pid"
    sleep 1

    if ps -p "$pid" >/dev/null 2>&1; then
        echo -e "${YELLOW}Force stopping...${NC}"
        kill -9 "$pid"
    fi

    rm -f "$pid_file"
    echo -e "${GREEN}Instance stopped${NC}"
}

show_instance_status() {
    local port="${INSTANCE_PORT_START:-8081}"

    shift  # Remove "status" command
    while [[ $# -gt 0 ]]; do
        case $1 in
            --port)
                port="$2"
                shift 2
                ;;
            *)
                # If no --port flag, treat the argument as port number
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    port="$1"
                fi
                shift
                ;;
        esac
    done

    local pid_file="$INSTANCES_DIR/$port.pid"

    echo -e "${BLUE}LLM Instance (port $port):${NC}"

    if [ ! -f "$pid_file" ]; then
        echo -e "  ${YELLOW}○ not running${NC}"
        return 0
    fi

    local pid=$(cat "$pid_file")

    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}○ not running${NC} (stale PID file)"
        rm -f "$pid_file"
        return 0
    fi

    echo -e "  ${GREEN}● running${NC} PID $pid | $(get_process_info "$pid")"

    local log_file="$LOGS_DIR/instance-$port.log"
    if [ -f "$log_file" ]; then
        echo -e "     Log: $log_file"
    fi
}

show_all_status() {
    echo -e "${BLUE}LLM Status:${NC}"
    echo ""
    show_service_status
    echo ""
    echo -e "${BLUE}Instances:${NC}"
    show_all_instances
}

# ==================== PRUNE COMMAND ====================

prune_models() {
    local dry_run=1
    if [ "${1:-}" = "--force" ]; then
        dry_run=0
    fi

    local section="" backend="" model_path="" is_hf_model=0
    local in_args=0 in_section=0
    local -a remove_sections=()

    echo -e "${BLUE}Scanning models for invalid entries...${NC}"
    echo ""

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            # Validate previous section (skip profile sections)
            if [ -n "$section" ] && [[ "$section" != profile.* ]]; then
                local reason=""
                if [ -z "$backend" ]; then
                    reason="no backend"
                elif ! get_backend_binary "$backend" >/dev/null 2>&1; then
                    reason="backend '$backend' not found in llm.conf"
                elif [ "$is_hf_model" -eq 0 ] && [ -z "$model_path" ]; then
                    reason="no model path (-m) found"
                elif [ "$is_hf_model" -eq 0 ] && [ ! -e "$model_path" ]; then
                    reason="model path not found: $model_path"
                fi

                if [ -n "$reason" ]; then
                    remove_sections+=("$section")
                    echo -e "  ${RED}✗${NC} ${YELLOW}$section${NC} — $reason"
                fi
            fi

            section="${BASH_REMATCH[1]}"
            backend=""
            model_path=""
            is_hf_model=0
            in_args=0
            in_section=1
            continue
        fi

        # Track <args> block
        if [[ "$line" =~ ^[[:space:]]*\<args\>[[:space:]]*$ ]]; then
            in_args=1
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*\</args\>[[:space:]]*$ ]]; then
            in_args=0
            continue
        fi

        if [ $in_args -eq 1 ] && [ -z "$model_path" ]; then
            # Strip trailing backslash (line continuation)
            local stripped
            stripped=$(echo "$line" | sed 's/\\$//' | xargs 2>/dev/null)
            [ -z "$stripped" ] && continue

            # Detect -hf (HuggingFace remote model — no local path needed)
            if [[ "$stripped" =~ ^-hf[[:space:]]+([^[:space:]]+) ]]; then
                is_hf_model=1
            # Extract -m path
            elif [[ "$stripped" =~ ^-m[[:space:]]+([^[:space:]]+) ]]; then
                model_path="${BASH_REMATCH[1]}"
            # Extract positional model path (vLLM: first non-flag arg)
            elif [[ ! "$stripped" =~ ^- ]]; then
                model_path="$stripped"
            fi

            model_path="${model_path/#\$HOME/$HOME}"
            model_path="${model_path/#\~/$HOME}"
        fi

        # Parse backend= from metadata
        if [ $in_args -eq 0 ] && [[ "$line" =~ ^[[:space:]]*backend=(.*)$ ]]; then
            backend=$(trim "${BASH_REMATCH[1]}" | tr -d '"')
        fi
    done < "$MODELS_CONF"

    # Validate last section (skip profile sections)
    if [ -n "$section" ] && [[ "$section" != profile.* ]]; then
        local reason=""
        if [ -z "$backend" ]; then
            reason="no backend"
        elif ! get_backend_binary "$backend" >/dev/null 2>&1; then
            reason="backend '$backend' not found in llm.conf"
        elif [ "$is_hf_model" -eq 0 ] && [ -z "$model_path" ]; then
            reason="no model path (-m) found"
        elif [ "$is_hf_model" -eq 0 ] && [ ! -e "$model_path" ]; then
            reason="model path not found: $model_path"
        fi
        if [ -n "$reason" ]; then
            remove_sections+=("$section")
            echo -e "  ${RED}✗${NC} ${YELLOW}$section${NC} — $reason"
        fi
    fi

    if [ ${#remove_sections[@]} -eq 0 ]; then
        echo -e "  ${GREEN}All models valid — nothing to prune${NC}"
        return 0
    fi

    echo ""
    echo -e "  ${YELLOW}${#remove_sections[@]} model(s) would be removed${NC}"
    echo ""

    if [ $dry_run -eq 1 ]; then
        echo -e "  ${BLUE}Dry run — no changes made.${NC}"
        echo "  Run with ${GREEN}--force${NC} to apply."
        return 0
    fi

    # Build removal set
    local -A to_remove
    for s in "${remove_sections[@]}"; do
        to_remove["$s"]=1
    done

    # Rewrite models.conf without the pruned sections
    local tmp_file
    tmp_file=$(mktemp)
    local skip=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [ -n "${to_remove[${BASH_REMATCH[1]}]}" ]; then
                skip=1
            else
                skip=0
                echo "$line" >> "$tmp_file"
            fi
            continue
        fi

        if [ $skip -eq 1 ]; then
            continue
        fi

        echo "$line" >> "$tmp_file"
    done < "$MODELS_CONF"

    # Backup and replace
    cp "$MODELS_CONF" "${MODELS_CONF}.bak"
    mv "$tmp_file" "$MODELS_CONF"

    echo -e "  ${GREEN}Pruned ${#remove_sections[@]} model(s).${NC}"
    echo -e "  Backup saved to ${MODELS_CONF}.bak"
}

# ==================== COMMAND DISPATCHER ====================

case "${1:-}" in
    serve)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: serve requires a model name${NC}"
            echo "Usage: llm serve <model> [profile] [backend]"
            exit 1
        fi
        shift  # Remove "serve"
        serve_model "$@"
        ;;
    start)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: start requires a model name${NC}"
            echo "Usage: llm start <model> [profile] [backend] [--port PORT]"
            exit 1
        fi
        shift  # Remove "start"
        start_instance "$@"
        ;;
    stop)
        if [ "$2" = "service" ]; then
            stop_service
        elif [ "$2" = "--port" ] || [ "$2" = "-p" ]; then
            stop_instance "$@"
        elif [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
            stop_instance "--port" "$2"
        else
            stop_all_instances
        fi
        ;;
    restart)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: restart requires a model name${NC}"
            echo "Usage: llm restart <model> [profile] [backend]"
            exit 1
        fi
        shift  # Remove "restart"
        restart_service "$@"
        ;;
    status)
        if [ "$2" = "--port" ] || [ "$2" = "-p" ]; then
            show_instance_status "$@"
        elif [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
            show_instance_status "--port" "$2"
        else
            show_all_status
        fi
        ;;
    logs)
        show_service_logs
        ;;
    enable)
        enable_service
        ;;
    disable)
        disable_service
        ;;
    list)
        list_models
        ;;
    prune)
        prune_models "$2"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        if [ -z "$1" ]; then
            show_all_status
        else
            echo -e "${RED}Unknown command: $1${NC}"
            echo ""
            usage
            exit 1
        fi
        ;;
esac
