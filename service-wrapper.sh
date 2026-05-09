#!/bin/bash
# LLM Service Wrapper - Called by systemd
# Reads the current model profile and starts the server

# Determine script location (no symlink following needed — systemd calls this directly via %h)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_DIR="$SCRIPT_DIR"

# Config location
LLM_CONF="${LLM_CONF:-$LLM_DIR/llm.conf}"

# Source shared library
source "$LLM_DIR/lib.sh"

# Load config or use defaults
if [ -f "$LLM_CONF" ]; then
    load_config "$LLM_CONF"
fi

# Export LLM_CONF so get_backend_binary can find backends in llm.conf
export LLM_CONF

# Set defaults for any missing values
MODELS_DIR="${MODELS_DIR:-$LLM_DIR/models}"
SERVICE_PORT="${SERVICE_PORT:-4444}"

CURRENT_MODEL_FILE="$LLM_DIR/current_model"
LOGS_DIR="$LLM_DIR/logs"

# Read current model (extended format: model_id|backend|profile)
if [ ! -f "$CURRENT_MODEL_FILE" ]; then
    echo "No model selected. Use 'llm serve <model>' first." >&2
    exit 78
fi

CURRENT_PARSED=$(read_current_model "$CURRENT_MODEL_FILE") || exit 78
IFS='|' read -r MODEL_ID RUNTIME_BACKEND RUNTIME_PROFILE <<< "$CURRENT_PARSED"
MODELS_CONF="$LLM_DIR/models.conf"

# Resolve backend: runtime override > model config default
BACKEND="${RUNTIME_BACKEND:-$(get_config "$MODEL_ID" "backend")}"
if [ -z "$BACKEND" ]; then
    echo "No backend configured for model '$MODEL_ID'" >&2
    exit 78
fi

# Resolve profile: runtime override > model config default
PROFILE="${RUNTIME_PROFILE:-$(get_config "$MODEL_ID" "profile")}"

echo "Starting LLM service with model: $MODEL_ID (port $SERVICE_PORT)"
echo "Backend: $BACKEND"
[ -n "$PROFILE" ] && echo "Profile: $PROFILE"

# Validate backend before building command (exit 78 prevents systemd restart loop)
if ! validate_backend "$MODEL_ID" "$BACKEND"; then
    exit 78
fi

# Build and exec the command
if ! build_cmdline "$MODEL_ID" "$SERVICE_PORT" "$BACKEND" "$PROFILE"; then
    echo "Configuration error for model '$MODEL_ID' - stopping service" >&2
    exit 78
fi
mkdir -p "$LOGS_DIR"

# Use timestamped log to prevent systemd restart loops from overwriting errors
LOG_FILE="$LOGS_DIR/llm-service-$(date +%Y%m%d-%H%M%S).log"

# Log start info
echo "=== LLM Service Start ===" >> "$LOG_FILE"
echo "Timestamp: $(date -Iseconds)" >> "$LOG_FILE"
echo "Model: $MODEL_ID" >> "$LOG_FILE"
echo "Backend: $BACKEND" >> "$LOG_FILE"
[ -n "$PROFILE" ] && echo "Profile: $PROFILE" >> "$LOG_FILE"
echo "Port: $SERVICE_PORT" >> "$LOG_FILE"
echo "Command: ${CMD_ARRAY[*]}" >> "$LOG_FILE"
echo "========================" >> "$LOG_FILE"

# Link to latest log
ln -sf "$LOG_FILE" "$LOGS_DIR/llm-service.log"

# Rotate old logs to keep directory from growing unbounded
rotate_old_logs() {
    local dir="$1"
    local pattern="$2"
    local keep="${3:-10}"
    ls -t "$dir"/$pattern 2>/dev/null | tail -n +$((keep + 1)) | xargs rm -f 2>/dev/null || true
}
rotate_old_logs "$LOGS_DIR" "llm-service-*.log" 10

# Activate venv if backend requires it
activate_backend_venv "$BACKEND"

# Execute the server
exec "${CMD_ARRAY[@]}" >> "$LOG_FILE" 2>&1
