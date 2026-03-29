# LLM Management Solution

A sophisticated LLM (Large Language Model) management system built around `llama.cpp` that provides a CLI interface and systemd service wrapper for running multiple models locally on different hardware (CPU, Vulkan GPU, CUDA GPU).

## Features

- **Multi-model management**: Configure and switch between multiple GGUF models
- **Multi-hardware support**: CPU-only, Vulkan GPU, and CUDA GPU builds
- **Service-based architecture**: Persistent systemd service with auto-restart
- **Instance management**: Run additional temporary instances on different ports
- **Centralized configuration**: INI-style config file for all model settings
- **Automatic service installation**: Service installs on first `llm serve` command

## Prerequisites

1. **llama.cpp builds**: Compile or download llama.cpp builds for your hardware:
   - CPU-only build: `llama.cpp` or `ik_llama.cpp`
   - Vulkan GPU build: `llama.cpp.vulkan`
   - CUDA GPU build: `llama.cpp.cuda`
   - ROCm GPU build: `llama.cpp.rocm`

   Each build must have the `llama-server` binary at `<build>/bin/llama-server`

2. **systemd**: Required for service management (most Linux distributions include it)

3. **GGUF model files**: Download quantized models in GGUF format

## Installation

1. **Copy the launcher script**:
   ```bash
   sudo cp ~/.llm/launcher.sh /usr/local/bin/llm
   sudo chmod +x /usr/local/bin/llm
   ```

   Alternatively, add `~/.llm` to your PATH:
   ```bash
   echo 'export PATH="$HOME/.llm:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

2. **Verify directory structure**:
   ```bash
   ~/.llm/
   ├── models.conf          # Model configurations
   ├── service-wrapper.sh   # Systemd service entry point
   ├── llm.service          # Systemd unit file
   ├── launcher.sh          # CLI launcher script
   ├── current_model        # Runtime file (active service model)
   ├── models/              # GGUF model files
   ├── instances/           # PID files for instances
   └── logs/                # Service and instance logs
   ```

3. **Configure your models** (see Configuration section below)

4. **Download GGUF models** to `~/.llm/models/`

## Directory Structure

```
~/.llm/
├── models.conf           # INI-style model configurations
├── service-wrapper.sh    # Systemd service entry point
├── llm.service           # Systemd unit file
├── launcher.sh           # CLI launcher (copy to /usr/local/bin/llm)
├── current_model         # Active service model (runtime)
├── models/               # GGUF model files directory
│   ├── qwen/
│   ├── glm/
│   └── ...
├── instances/            # PID files for temporary instances
│   ├── 8081.pid
│   └── 8082.pid
└── logs/                 # Log files
    ├── llm-service.log   # Current service log
    ├── llm-service.log.1 # Rotated logs
    └── instance-8081.log # Instance logs
```

## Infrastructure Configuration

The file `~/.llm/llm.conf` controls system-wide settings like ports and model directory:

```ini
# LLM Infrastructure Configuration
models_dir=$llm_dir/models
service_port=4444
instance_port_start=8081
systemd_user_dir=$HOME/.config/systemd/user
```

The base directory (`llm_dir`) is automatically detected from the script location.

### Infrastructure Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `models_dir` | Directory for GGUF model files (supports `$llm_dir`, `$HOME`, `~`) | `$llm_dir/models` |
| `service_port` | Port for the main systemd service | 4444 |
| `instance_port_start` | Starting port for temporary instances | 8081 |
| `systemd_user_dir` | Systemd user service directory | `$HOME/.config/systemd/user` |

> **Note**: You can override the config file location by setting the `LLM_CONF` environment variable.
>
> **Note**: The `$llm_dir` variable in `models_dir` expands to the detected script directory. You can also use `$HOME` and `~` for paths outside the project.

## Model Configuration

Edit `~/.llm/models.conf` to add models. Each model has a section header `[model-id]`, metadata fields, and an `<args>` block containing raw CLI flags passed directly to `llama-server`:

```ini
[my-model]
name="My Model Display Name"
description="Brief description"
build="/path/to/llama.cpp/build"
model="$HOME/.llm/models/my-model.gguf"
<args>
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
| `build` | Yes | Path to llama.cpp build directory (must contain `bin/llama-server`) |
| `model` | Yes | Path to GGUF model file (supports `$HOME` and `~` expansion) |

### Args Block

The `<args>...</args>` block contains raw `llama-server` CLI flags. Use `\` for line continuation. Supports `$HOME` and `~` expansion. New llama.cpp flags can be added here without any wrapper changes.

Common flags: `--ctx-size`, `--threads`, `--device`, `--gpu-layers`, `--flash-attn`, `--jinja`, `--temp`, `--top-p`, `--top-k`, `--min-p`, `--parallel`, `--mmproj`, `--cache-type-v`, `--cache-type-k`, `--split-mode`, `--tensor-split`, `--n-cpu-moe`, `--kv-unified`, `--swa-full`, `--no-mmap`, `--chat-template-file`

## Usage

### Service Commands (port 4444, persistent)

The main service runs on port 4444 and is managed by systemd with auto-restart.

```bash
# Start service with a model
llm serve qwen-35b-vulkan

# Restart service with different model
llm restart glm-4.7-vulkan

# Stop the service
llm stop service

# Show service status
llm status

# Follow service logs
llm logs

# Enable service on boot
llm enable

# Disable service on boot
llm disable
```

### Instance Commands (additional instances)

Run temporary instances on different ports for concurrent model access.

```bash
# Start instance on default port 8081
llm start qwen-9b-vulkan

# Start instance on custom port
llm start loki-vulkan --port 8082

# Stop all instances
llm stop

# Stop specific instance
llm stop --port 8081

# Check instance status
llm status --port 8081
```

### Other Commands

```bash
# List all configured models
llm list

# Show help
llm help
```

## How It Works

### Service Wrapper Flow

```
systemd -> service-wrapper.sh -> reads llm.conf -> reads current_model
    -> parses models.conf -> builds llama-server command -> exec
```

1. **`llm serve <model>`** writes model ID to `current_model` and starts systemd
2. **systemd** executes `service-wrapper.sh`
3. **service-wrapper.sh** reads `current_model` and parses `models.conf`
4. **Command built** from config variables
5. **llama-server** runs as systemd service (auto-restart on crash)

### Port Allocation

Ports are configured in `~/.llm/llm.conf`. Default allocation:

| Type | Default Port | Management |
|------|--------------|------------|
| Main service | 4444 | systemd, persistent |
| Instance 1 | instance_port_start (8081) | background process |
| Instance 2 | instance_port_start + 1 | background process |
| ... | ... | ... |

## Examples

### Basic CPU-only model

```ini
[my-cpu-model]
name="My CPU Model"
description="Lightweight model for CPU inference"
build="$HOME/llama.cpp"
model="$HOME/.llm/models/my-model-Q4_K_M.gguf"
<args>
--ctx-size 4096 \
--threads 4
</args>
```

### Vulkan GPU model

```ini
[my-gpu-model]
name="My GPU Model"
description="Fast GPU inference"
build="/opt/llama.cpp.vulkan"
model="$HOME/.llm/models/my-model-Q4_K_M.gguf"
<args>
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
build="/opt/llama.cpp.vulkan"
model="$HOME/.llm/models/my-model.gguf"
<args>
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
build="/opt/llama.cpp.vulkan"
model="$HOME/.llm/models/my-model.gguf"
<args>
--mmproj $HOME/.llm/models/my-mmproj.gguf \
--ctx-size 4096 \
--device Vulkan0
</args>
```

## Troubleshooting

### Service fails to start

1. Check logs:
   ```bash
   journalctl --user -u llm.service -n 50
   ```

2. Verify model file exists and is readable

3. Verify llama.cpp build path is correct

4. Check GPU device name with `vulkaninfo` or `nvidia-smi`

### Port already in use

```bash
# Find what's using the port
sudo lsof -i :4444

# Stop the service or instance using the port
llm stop service
llm stop --port 8081
```

### Model not found

```bash
# List available models and check their status
llm list

# Verify model file exists
ls -la ~/.llm/models/
```

### Permission denied

```bash
# Ensure launcher is executable
chmod +x ~/.llm/launcher.sh

# If using /usr/local/bin/llm
sudo chmod +x /usr/local/bin/llm
```

### Check current status

```bash
# Show full status including all instances
llm status

# Check specific instance
llm status --port 8081
```

## Systemd Integration

The service file uses `%h` for home directory expansion, which systemd resolves to the user's home directory. The service is installed as a **user service** (not system-wide), running without root privileges.

### Manual service installation

```bash
mkdir -p ~/.config/systemd/user
cp ~/.llm/llm.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

### Enable at login

```bash
# Enable service to start on user login
llm enable

# Disable
llm disable
```

## License

This management wrapper is provided as-is for use with llama.cpp (GPLv3).
