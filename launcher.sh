#!/bin/bash
# LLM Launcher - Manage multiple llama.cpp models and builds
# Usage: llm [command] [model]

set -e

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
    echo "Usage: llm <command> [model] [options]"
    echo ""
    echo "Service Commands (port $svc_port, persistent):"
    echo "  serve <model>   Set model and start systemd service on port $svc_port"
    echo "  restart <model> Restart service with new model"
    echo "  stop service    Stop the systemd service"
    echo "  status          Show service and instances status"
    echo "  logs            Show service logs"
    echo "  enable          Enable service on boot"
    echo "  disable         Disable service on boot"
    echo ""
    echo "Instance Commands (additional instances):"
    echo "  start <model> [--port PORT]  Start instance on port (default: $inst_port)"
    echo "  stop [--port PORT]            Stop instance(s) (default: all)"
    echo ""
    echo "Other Commands:"
    echo "  list            List available models"
    echo "  help            This help"
    echo ""
    echo "Examples:"
    echo "  llm serve qwen-35b-vulkan     # Start service on port $svc_port"
    echo "  llm start glm-4.7-vulkan      # Start instance on port $inst_port"
    echo "  llm start loki-vulkan --port $((inst_port + 1))"
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



# Print a model entry for list_models
_print_model_entry() {
    local model_id="$1" name="$2" description="$3" build_path="$4" current="$5"

    local status=""

    if [ -n "$build_path" ] && [ -d "$build_path" ]; then
        if [ -x "$build_path/bin/llama-server" ]; then
            status="${GREEN}✓${NC}"
        else
            status="${YELLOW}⚠${NC}"
        fi
    else
        status="${YELLOW}⚠${NC}"
    fi

    local current_indicator=""
    if [ "$model_id" = "$current" ]; then
        current_indicator="${BLUE}[CURRENT]${NC} "
    fi

    echo -e "  ${YELLOW}$model_id${NC} $current_indicator$status"
    echo -e "    $name"
    echo -e "    $description"
    echo ""
}

# List models (single-pass parse)
list_models() {
    echo -e "${BLUE}Available Models:${NC}"
    echo ""

    local current=""
    if [ -f "$CURRENT_MODEL_FILE" ]; then
        current=$(cat "$CURRENT_MODEL_FILE")
    fi

    local section="" name="" description="" build_path=""
    local in_args=0

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            # Print previous section
            if [ -n "$section" ]; then
                _print_model_entry "$section" "$name" "$description" "$build_path" "$current"
            fi
            section="${BASH_REMATCH[1]}"
            name="" description="" build_path=""
            in_args=0
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
            key=$(echo "${BASH_REMATCH[1]}" | xargs)
            value=$(echo "${BASH_REMATCH[2]}" | xargs | tr -d '"')
            value="${value/#\$HOME/$HOME}"
            value="${value/#\~/$HOME}"

            case "$key" in
                name) name="$value" ;;
                description) description="$value" ;;
                build) build_path="$value" ;;
            esac
        fi
    done < "$MODELS_CONF"

    # Print last section
    if [ -n "$section" ]; then
        _print_model_entry "$section" "$name" "$description" "$build_path" "$current"
    fi
}

get_current_model() {
    if [ -f "$CURRENT_MODEL_FILE" ]; then
        cat "$CURRENT_MODEL_FILE"
    fi
}

get_service_status() {
    systemctl --user is-enabled llm.service 2>/dev/null && echo "enabled" || echo "disabled"
    systemctl --user is-active llm.service 2>/dev/null && echo "active" || echo "inactive"
}

# ==================== SERVICE COMMANDS ====================

serve_model() {
    ensure_service
    local model_id="$1"

    # Validate model exists
    if ! grep -q "^\[$model_id\]" "$MODELS_CONF"; then
        echo -e "${RED}Error: Model '$model_id' not found${NC}"
        echo "Use 'llm list' to see available models"
        return 1
    fi

    local binary=$(get_config "$model_id" "binary")
    if [ ! -x "$binary" ]; then
        echo -e "${RED}Error: Binary not found: $binary${NC}"
        return 1
    fi

    # Save current model
    echo "$model_id" > "$CURRENT_MODEL_FILE"

    # Get model info
    local name=$(get_config "$model_id" "name")

    echo -e "${BLUE}Setting service model:${NC} $name"
    echo -e "Model ID: $model_id"
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

    # Wait for service to start
    if wait_for_port "$SERVICE_PORT" 10; then
        echo -e "${GREEN}Service started successfully${NC}"
        echo ""
        echo "Recent logs:"
        journalctl --user -u llm.service -n 20 --no-pager
    else
        echo -e "${RED}Service failed to start${NC}"
        echo ""
        echo "Service logs:"
        journalctl --user -u llm.service -n 50 --no-pager
        return 1
    fi
}

stop_service() {
    ensure_service

    if systemctl --user is-active llm.service >/dev/null 2>&1; then
        echo -e "${YELLOW}Stopping service...${NC}"
        systemctl --user stop llm.service
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
                echo -e "${YELLOW}Stopping instance on port $port...${NC}"
                kill "$pid"
                sleep 0.5
                if ps -p "$pid" >/dev/null 2>&1; then
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
    local model_id="$1"
    stop_service
    sleep 2
    serve_model "$model_id"
}

show_service_status() {
    ensure_service

    local current=$(get_current_model)
    local enabled_status=$(get_service_status | head -1)
    local active_status=$(get_service_status | tail -1)

    echo -e "${BLUE}LLM Service (port $SERVICE_PORT):${NC}"

    if [ "$active_status" = "active" ]; then
        if [ -n "$current" ]; then
            local name=$(get_config "$current" "name" 2>/dev/null || echo "$current")
            local pid=$(systemctl --user show -p MainPID --value llm.service 2>/dev/null || echo "unknown")

            echo -e "  ${GREEN}● running${NC} ${BLUE}$name${NC}"
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
        local elapsed=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
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
    local model_id="$1"
    local port="${INSTANCE_PORT_START:-8081}"

    shift  # Remove model_id
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

    # Validate model exists
    if ! grep -q "^\[$model_id\]" "$MODELS_CONF"; then
        echo -e "${RED}Error: Model '$model_id' not found${NC}"
        echo "Use 'llm list' to see available models"
        return 1
    fi

    local binary=$(get_config "$model_id" "binary")
    if [ ! -x "$binary" ]; then
        echo -e "${RED}Error: Binary not found: $binary${NC}"
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

    echo -e "${BLUE}Starting instance:${NC} $name"
    echo -e "Model ID: $model_id"
    echo -e "Port: $port"
    echo ""

    # Build command
    build_cmdline "$model_id" "$port"

    # Create log file with rotation
    local log_file="$LOGS_DIR/instance-$port.log"
    mkdir -p "$LOGS_DIR"

    # Rotate instance logs
    rotate_log "$log_file"

    # Start in background
    nohup "${CMD_ARRAY[@]}" >> "$log_file" 2>&1 &
    local pid=$!

    # Save PID
    echo "$pid" > "$pid_file"

    # Wait for instance to start
    if wait_for_port "$port" 10; then
        echo -e "${GREEN}Instance started successfully${NC}"
        echo -e "  PID: $pid"
        echo -e "  Log: $log_file"
        echo ""
        echo "Recent logs:"
        tail -n 20 "$log_file"
    else
        echo -e "${RED}Instance failed to start${NC}"
        echo ""
        echo "Logs:"
        cat "$log_file"
        rm -f "$pid_file"
        return 1
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

# ==================== COMMAND DISPATCHER ====================

case "${1:-}" in
    serve)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: serve requires a model name${NC}"
            echo "Usage: llm serve <model>"
            exit 1
        fi
        serve_model "$2"
        ;;
    start)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: start requires a model name${NC}"
            echo "Usage: llm start <model> [--port PORT]"
            exit 1
        fi
        shift  # Remove "start" from args
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
            echo "Usage: llm restart <model>"
            exit 1
        fi
        restart_service "$2"
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
