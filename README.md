# LLM Manager

A management system for `llama.cpp` that provides a CLI interface and systemd service wrapper for running multiple GGUF models locally on different hardware backends (CPU, Vulkan, CUDA, ROCm).

## Features

- **Multi-model management**: Configure and switch between multiple GGUF models
- **Multi-hardware support**: CPU-only, Vulkan GPU, CUDA GPU, and ROCm GPU builds
- **Service-based architecture**: Persistent systemd service with auto-restart
- **Instance management**: Run additional temporary instances on different ports
- **Centralized configuration**: INI-style config file for all model settings
- **HuggingFace support**: Auto-download models with `--hf-repo` / `--hf-file`
- **Automatic service installation**: Service installs on first `llm serve` command

## Prerequisites

1. **llama.cpp builds**: Compile or download llama.cpp builds for your hardware.
   Each build must have the `llama-server` binary available at the path specified in `binary=`

2. **systemd**: Required for service management (most Linux distributions include it)

3. **GGUF model files**: Download quantized models, or use HuggingFace auto-download

## Installation

Clone the repo to your preferred location (referred to as `$LLM_DIR` below):

```bash
git clone https://github.com/Zorgonatis/llm-manager.git ~/llm-manager
```

Create the CLI symlink:

```bash
ln -s ~/llm-manager/launcher.sh ~/.local/bin/llm
```

> `~/.local/bin` is part of the XDG standard and is already in PATH on most Linux distributions. If it isn't:
> ```bash
> # Fish:
> echo 'set -gx PATH $PATH ~/.local/bin' >> ~/.config/fish/config.fish
> # Bash:
> echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
> ```

Alternatively, install system-wide:

```bash
sudo ln -s ~/llm-manager/launcher.sh /usr/local/bin/llm
```

## Directory Structure

```
$LLM_DIR/
├── models.conf           # INI-style model configurations
├── service-wrapper.sh    # Systemd service entry point
├── llm.service           # Systemd unit file
├── launcher.sh           # CLI launcher
├── llm.conf              # Infrastructure config (ports, paths)
├── current_model         # Active service model (runtime)
├── models/               # GGUF model files directory
├── instances/            # PID files for temporary instances
└── logs/                 # Service and instance logs
```

## Infrastructure Configuration

`llm.conf` controls system-wide settings like ports and model directory:

```ini
models_dir=$llm_dir/models
service_port=4444
instance_port_start=8081
```

The base directory (`llm_dir`) is automatically detected from the script location.

| Variable | Description | Default |
|----------|-------------|---------|
| `models_dir` | Directory for GGUF model files (supports `$llm_dir`, `$HOME`, `~`) | `$llm_dir/models` |
| `service_port` | Port for the main systemd service | 4444 |
| `instance_port_start` | Starting port for temporary instances | 8081 |

> **Note**: Override the config file location by setting the `LLM_CONF` environment variable.
> The `$llm_dir` variable expands to the detected script directory. You can also use `$HOME` and `~` for paths outside the project.

## Model Configuration

Edit `models.conf` to add models. Each model has a section header `[model-id]`, metadata fields, and an `<args>` block containing raw CLI flags passed directly to `llama-server`:

```ini
[my-model]
name="My Model Display Name"
description="Brief description"
binary="/path/to/llama.cpp/bin/llama-server"
<args>
-m $HOME/models/my-model.gguf \
--ctx-size 8192 \
--threads -1 \
--device Vulkan0 \
--flash-attn auto \
--jinja \
--temp 1.0 \
--top-p 0.95
</args>
```

### Metadata Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Display name (defaults to section ID) |
| `description` | No | Model description |
| `binary` | Yes | Path to the `llama-server` executable |

### Args Block

The `<args>...</args>` block contains raw `llama-server` CLI flags — including `-m` for the model path. Use `\` for line continuation. Supports `$HOME` and `~` expansion. New llama.cpp flags can be added here without any wrapper changes.

### HuggingFace Auto-Download

Use `--hf-repo` and `--hf-file` instead of `-m` to auto-download models:

```ini
[hf-model]
name="HF Auto-Download Model"
description="Auto-downloaded from HuggingFace"
binary="/opt/llama.cpp/bin/llama-server"
<args>
--hf-repo Qwen/Qwen3-0.6B-GGUF \
--hf-file qwen3-0.6b-q8_0.gguf \
--ctx-size 4096 \
--threads 4
</args>
```

Common flags: `-m`, `--hf-repo`, `--hf-file`, `--ctx-size`, `--threads`, `--device`, `--gpu-layers`, `--flash-attn`, `--jinja`, `--temp`, `--top-p`, `--top-k`, `--min-p`, `--parallel`, `--mmproj`, `--cache-type-v`, `--cache-type-k`, `--split-mode`, `--tensor-split`, `--n-cpu-moe`, `--kv-unified`, `--swa-full`, `--no-mmap`, `--chat-template-file`

## Usage

### Service Commands (persistent, systemd-managed)

```bash
llm serve <model>          # Start service with a model
llm restart <model>        # Restart service with different model
llm stop service           # Stop the service
llm status                 # Show service and instances status
llm logs                   # Follow service logs
llm enable                 # Enable service on boot
llm disable                # Disable service on boot
```

### Instance Commands (additional temporary instances)

```bash
llm start <model> [--port PORT]   # Start instance (default port from config)
llm stop [--port PORT]            # Stop instance(s) (default: all)
llm status --port PORT            # Check specific instance status
```

### Other Commands

```bash
llm list           # List all configured models
llm help           # Show help
```

## How It Works

```
systemd -> service-wrapper.sh -> reads llm.conf -> reads current_model
    -> parses models.conf -> builds llama-server command from <args> block -> exec
```

1. **`llm serve <model>`** writes model ID to `current_model` and starts systemd
2. **systemd** executes `service-wrapper.sh`
3. **service-wrapper.sh** reads `current_model` and parses `models.conf`
4. **Command built** from `binary` path + `<args>` block
5. **llama-server** runs as systemd service (auto-restart on crash)

### Port Allocation

Configured in `llm.conf`:

| Type | Default Port | Management |
|------|--------------|------------|
| Main service | 4444 | systemd, persistent |
| Instance 1 | instance_port_start (8081) | background process |
| Instance 2 | instance_port_start + 1 | background process |

## Examples

### Basic CPU-only model

```ini
[my-cpu-model]
name="My CPU Model"
description="Lightweight model for CPU inference"
binary="/opt/llama.cpp/bin/llama-server"
<args>
-m $HOME/models/my-model-Q4_K_M.gguf \
--ctx-size 4096 \
--threads 4
</args>
```

### Vulkan GPU model

```ini
[my-gpu-model]
name="My GPU Model"
description="Fast GPU inference"
binary="/opt/llama.cpp.vulkan/bin/llama-server"
<args>
-m $HOME/models/my-model-Q4_K_M.gguf \
--ctx-size 8192 \
--device Vulkan0 \
--flash-attn auto \
--jinja \
--temp 1.0 \
--top-p 0.95
</args>
```

### Multi-GPU split model

```ini
[my-multi-gpu]
name="Multi-GPU Model"
description="Model split across two GPUs"
binary="/opt/llama.cpp.vulkan/bin/llama-server"
<args>
-m $HOME/models/my-model.gguf \
--ctx-size 131072 \
--device Vulkan0,Vulkan1 \
--split-mode layer \
--tensor-split 0.7,0.3 \
--gpu-layers 99
</args>
```

### Multimodal vision model

```ini
[my-vision-model]
name="Vision Model"
description="Multimodal model with vision support"
binary="/opt/llama.cpp.vulkan/bin/llama-server"
<args>
-m $HOME/models/my-model.gguf \
--mmproj $HOME/models/my-mmproj.gguf \
--ctx-size 4096 \
--device Vulkan0
</args>
```

## Troubleshooting

### Service fails to start

```bash
journalctl --user -u llm.service -n 50
```

1. Verify the `binary` path in models.conf points to an executable `llama-server`
2. Check GPU device name with `vulkaninfo` or `nvidia-smi`

### Port already in use

```bash
# Find what's using the port
sudo lsof -i :4444
```

### Model not found

```bash
llm list
```

### Permission denied

```bash
chmod +x $LLM_DIR/launcher.sh
```

## Systemd Integration

The service file uses `%h` for home directory expansion, which systemd resolves to the user's home directory. The service is installed as a **user service** (not system-wide), running without root privileges.

### Enable at login

```bash
llm enable    # Enable service to start on user login
llm disable   # Disable
```

## License

Provided as-is for use with llama.cpp (GPLv3).
