# Installation Guide

## Prerequisites

- **llama.cpp prebuilt binaries** — You need one or more builds of [llama.cpp](https://github.com/ggml-org/llama.cpp) compiled for your hardware. Each build must contain `bin/llama-server`. Common builds:
  - **Vulkan** — Any GPU with Vulkan support
  - **ROCm** — AMD GPUs
  - **CUDA** — NVIDIA GPUs
  - **CPU** — `ik_llama.cpp` or standard llama.cpp CPU build
- **GGUF model files** — Quantized models in GGUF format (or use HuggingFace auto-download)
- **bash** — Shell for the launcher scripts
- **systemd** — For service management (user-session)

## Clone and Setup

```bash
# Clone the repo to your preferred location
git clone https://github.com/Zorgonatis/llm-manager.git ~/llm-manager

# Make scripts executable
chmod +x ~/llm-manager/launcher.sh ~/llm-manager/service-wrapper.sh

# Create the CLI symlink
mkdir -p ~/bin
ln -s ~/llm-manager/launcher.sh ~/bin/llm

# Add ~/bin to PATH (choose your shell)
# Fish:
echo 'set -gx PATH $PATH ~/bin' >> ~/.config/fish/config.fish
# Bash:
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## Prepare Your llama.cpp Builds

The `build` path in each model config must point to a directory containing `bin/llama-server`. For example:

```
/opt/llama.cpp/install-vulkan/bin/llama-server
/opt/llama.cpp/install-rocm/bin/llama-server
/opt/llama.cpp/install-cuda/bin/llama-server
```

Build llama.cpp from source or download prebuilt releases, then note the install prefix for each backend.

## Add a Model

1. Place your `.gguf` file in the models directory:

```bash
mkdir -p $LLM_DIR/models/my-model
cp model-Q4_K_M.gguf $LLM_DIR/models/my-model/
```

2. Add a config entry to `models.conf`:

```ini
[my-model]
name="My Model"
description="Q4_K_M quant on Vulkan GPU"
build="/opt/llama.cpp/install-vulkan"
<args>
-m $HOME/models/my-model/model-Q4_K_M.gguf \
--ctx-size 8192 \
--threads -1 \
--device Vulkan0 \
--parallel 1 \
--flash-attn auto \
--jinja \
--temp 1.0 \
--top-p 0.95
</args>
```

The `<args>` block contains raw `llama-server` CLI flags. Use `\` for line continuation. Any flag `llama-server` supports can go here — no wrapper changes needed.

## Start an Instance (Temporary)

Run a model as a background process for testing:

```bash
llm start my-model

# On a custom port:
llm start my-model --port 8082

# Check status:
llm status

# Stop:
llm stop
```

## Convert to a Persistent Service

Use `llm serve` to run the model as a systemd user service with auto-restart:

```bash
llm serve my-model
```

This installs the systemd unit file (if needed), writes the model selection to `current_model`, and starts the service on port 4444 (configurable in `llm.conf`).

```bash
# Check service status
llm status

# View logs (follow mode)
llm logs

# Restart with a different model
llm restart another-model

# Stop the service
llm stop service

# Enable on boot
llm enable
```

## Configuration Reference

### `llm.conf` — Infrastructure settings

| Variable | Default | Description |
|----------|---------|-------------|
| `models_dir` | `$llm_dir/models` | GGUF model files directory |
| `service_port` | `4444` | Persistent service port |
| `instance_port_start` | `8081` | First instance port |

### `models.conf` — Model configurations

Each model section has metadata fields and an `<args>` block:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Display name |
| `description` | No | Short description |
| `build` | Yes | Path to llama.cpp build (must contain `bin/llama-server`) |

All other options — including `-m` for the model path — are raw `llama-server` flags in the `<args>` block. For HuggingFace auto-download, use `--hf-repo` and `--hf-file` instead of `-m`. See `llama-server --help` for the full list.
