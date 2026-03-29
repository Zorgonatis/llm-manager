#!/bin/bash
# LLM Service Wrapper - Called by systemd
# Reads the current model profile and starts the server

set -e

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

# Set defaults for any missing values
MODELS_DIR="${MODELS_DIR:-$LLM_DIR/models}"
SERVICE_PORT="${SERVICE_PORT:-4444}"

CURRENT_MODEL_FILE="$LLM_DIR/current_model"
LOGS_DIR="$LLM_DIR/logs"

# Read current model
if [ ! -f "$CURRENT_MODEL_FILE" ]; then
    echo "No model selected. Use 'llm serve <model>' first." >&2
    exit 78
fi

MODEL_ID=$(cat "$CURRENT_MODEL_FILE")
MODELS_CONF="$LLM_DIR/models.conf"

echo "Starting LLM service with model: $MODEL_ID (port $SERVICE_PORT)"

# Validate paths before building command (exit 78 prevents systemd restart loop)
if ! validate_build_path "$MODEL_ID"; then
    exit 78
fi

# Build and exec the command
if ! build_cmdline "$MODEL_ID" "$SERVICE_PORT"; then
    echo "Configuration error for model '$MODEL_ID' - stopping service" >&2
    exit 78
fi
mkdir -p "$LOGS_DIR"

# Rotate logs
rotate_log "$LOGS_DIR/llm-service.log"

# Execute the server (exec replaces this script)
exec "${CMD_ARRAY[@]}" >> "$LOGS_DIR/llm-service.log" 2>&1
