# LLM Manager

A management system for `llama.cpp` (and vLLM) that provides a CLI interface and systemd service wrapper for running multiple models locally. Models are decoupled from hardware backends, so you can switch between CPU, Vulkan, CUDA, ROCm, and vLLM at runtime without editing config files.

## Features

- **Backend abstraction**: Define backends in `llm.conf`, override at runtime with `llm serve <model> rocm`
- **Profile system**: Reusable `<args>` blocks in `models.conf` for shared settings across models
- **Smart CLI parsing**: Profile and backend names are resolved against known sets, order-independent
- **Device injection**: Backend `device=` field auto-injects `--device` unless the model already specifies it
- **Service-based architecture**: Persistent systemd service with auto-restart
- **Instance management**: Additional temporary instances on different ports
- **Prune command**: Scan and remove models with missing backends or files
- **HuggingFace support**: Auto-download models with `--hf-repo` / `--hf-file`
- **vLLM support**: Backends with virtualenv activation and subcommand prefixes

## Prerequisites

1. **Server binaries**: Compile or download llama.cpp builds for your hardware. Each build must have the `llama-server` binary at the path specified in the backend's `binary=` field. For vLLM, install it in a virtualenv and point the backend at it.

2. **systemd**: Required for service management (most Linux distributions include it)

3. **Model files**: Download quantized GGUF models, or use HuggingFace auto-download

## Installation

Clone the repo:

```bash
git clone https://github.com/Zorgonatis/llm-manager.git ~/llm-manager
```

Create the CLI symlink:

```bash
ln -s ~/llm-manager/launcher.sh ~/.local/bin/llm
```

`~/.local/bin` is part of the XDG standard and is already in PATH on most distributions. If it isn't:

```bash
# Fish:
echo 'set -gx PATH $PATH ~/.local/bin' >> ~/.config/fish/config.fish
# Bash:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Alternatively, install system-wide:

```bash
sudo ln -s ~/llm-manager/launcher.sh /usr/local/bin/llm
```

## Directory Structure

```
$LLM_DIR/
├── models.conf           # Model and profile configurations
├── service-wrapper.sh    # Systemd service entry point
├── llm.service           # Systemd unit file
├── launcher.sh           # CLI launcher
├── lib.sh                # Shared functions
├── llm.conf              # Infrastructure config (ports, backends)
├── current_model         # Active service state (runtime)
├── models/               # GGUF model files directory
├── instances/            # PID files for temporary instances
└── logs/                 # Service and instance logs
```

## Infrastructure Configuration

`llm.conf` controls system-wide settings and backend definitions.

### Top-level settings

```ini
models_dir=$llm_dir/models
service_host=0.0.0.0
service_port=4444
instance_port_start=8081
```

| Variable | Description | Default |
|----------|-------------|---------|
| `models_dir` | Directory for GGUF model files (supports `$llm_dir`, `$HOME`, `~`) | `$llm_dir/models` |
| `service_host` | Host binding for services | `0.0.0.0` |
| `service_port` | Port for the main systemd service | 4444 |
| `instance_port_start` | Starting port for temporary instances | 8081 |

### Backend definitions

Backends are defined as `[backend.<name>]` sections. Each backend specifies the binary to run, optional GPU device, optional venv, and optional arg blocks:

```ini
[backend.rocm]
binary=/data-fast/apps/llama.cpp/install-rocm/bin/llama-server
device=ROCm0
<extra_args>
--alias local
</extra_args>

[backend.vllm]
binary=vllm
venv=/data-fast/apps/vllm/.venv
<backend_args>
serve
</backend_args>
<extra_args>
--served-model-name local
</extra_args>
```

| Field | Required | Description |
|-------|----------|-------------|
| `binary` | Yes | Path to the executable (or name if in PATH/venv) |
| `device` | No | GPU device string, auto-injected as `--device` flag |
| `venv` | No | Path to virtualenv to activate before running |

| Block | Description |
|-------|-------------|
| `<backend_args>` | Prefix arguments (e.g., `serve` for vLLM) |
| `<extra_args>` | Trailing arguments appended after model args |

The `device=` field is injected as `--device` at the end of the command line, but only if no `--device` flag is already present. This lets multi-GPU models specify their own device list without the backend overriding it.

> Override the config file location by setting the `LLM_CONF` environment variable.

## Model Configuration

`models.conf` holds model definitions and reusable profiles. Each model has a section header `[model-id]`, metadata fields, and an `<args>` block containing raw CLI flags:

```ini
[my-model]
name="My Model Display Name"
description="Brief description"
backend=rocm
profile=mem-tight
<args>
-m $HOME/models/my-model.gguf \
--ctx-size 8192 \
--threads -1
</args>
```

### Metadata fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Display name (defaults to section ID) |
| `description` | No | Model description |
| `backend` | Yes* | Default backend name (can be overridden at runtime) |
| `profile` | No | Default profile name (can be overridden at runtime) |

*Backends can also be specified at runtime via `llm serve <model> <backend>`, so a model can be backend-agnostic if you always pass one.

### Args block

The `<args>...</args>` block contains raw server CLI flags. Use `\` for line continuation. Supports `$HOME` and `~` expansion. New flags can be added without any wrapper changes.

### HuggingFace auto-download

Use `--hf-repo` and `--hf-file` instead of `-m` to auto-download models:

```ini
[hf-model]
name="HF Auto-Download Model"
description="Auto-downloaded from HuggingFace"
backend=cpu
<args>
--hf-repo Qwen/Qwen3-0.6B-GGUF \
--hf-file qwen3-0.6b-q8_0.gguf \
--ctx-size 4096 \
--threads 4
</args>
```

## Profiles

Profiles are reusable `<args>` blocks defined in `models.conf` under `[profile.<name>]` sections. Models reference them with `profile=<name>`. Profile args are merged before model args, so model args override profile defaults.

```ini
[profile.mem-tight]
<args>
--cache-type-v q8_0 --cache-type-k q8_0 \
--flash-attn auto --jinja --swa-full --no-mmap \
--gpu-layers 999 --temp 0.6 --min-p 0.0 --top-p 0.95 --top-k 20
</args>

[profile.high-fidelity]
<args>
--flash-attn auto --jinja --swa-full \
--gpu-layers 999 --temp 1.0 --top-p 0.95
</args>
```

A model uses a profile by setting `profile=mem-tight` in its config. The profile can also be overridden at runtime:

```bash
llm serve my-model high-fidelity
```

### Arg merge order

The final command line is assembled in this order (later args override earlier ones for most server binaries):

```
binary
 + backend_args       (from <backend_args> block, e.g. "serve")
 + profile_args       (from profile's <args> block)
 + model_args         (from model's <args> block)
 + extra_args         (from backend's <extra_args> block)
 + --host / --port    (injected from config)
 + [--device]         (injected from backend device=, unless already present)
```

This means model args override profile args, and extra_args (like `--alias`) are appended last.

### Backwards compatibility

Models without a `profile=` field work exactly as before. Old configs without profiles or backend sections are unaffected. The `<args>` block is all that's required for a working model.

## Usage

### Service commands (persistent, systemd-managed)

```bash
llm serve <model> [profile] [backend]   # Start/restart service with a model
llm restart <model> [profile] [backend] # Restart service with new model
llm stop service                        # Stop the systemd service
llm status                              # Show service and instances status
llm logs                                # Follow service logs
llm enable                              # Enable service on boot
llm disable                             # Disable service on boot
```

### Instance commands (additional temporary instances)

```bash
llm start <model> [profile] [backend] [--port PORT]   # Start instance
llm stop [--port PORT]                                 # Stop instance(s) (default: all)
llm stop <port-number>                                 # Stop instance by port number
```

### Other commands

```bash
llm list                     # List all configured models
llm prune                    # Scan for models with missing backends or files
llm prune --force            # Remove invalid entries from models.conf
llm help                     # Show help
```

### Smart CLI parsing

When you run `llm serve <model> [profile] [backend]`, the positional arguments after the model name are resolved against the known sets of profiles and backends defined in your config files. The order doesn't matter:

```bash
llm serve qwen-35b rocm              # Override backend
llm serve qwen-35b mem-tight         # Override profile
llm serve qwen-35b mem-tight rocm    # Override both (profile first)
llm serve qwen-35b rocm mem-tight    # Override both (backend first)
```

If a name matches both a profile and a backend, the CLI reports an ambiguity error. Unknown names are rejected with an error.

## How It Works

```
llm serve <model> [profile] [backend]
  -> resolve backend (runtime arg > model config > error)
  -> resolve profile (runtime arg > model config > none)
  -> write current_model file: "model_id|backend|profile"
  -> start/restart systemd service

systemd -> service-wrapper.sh -> reads current_model
  -> reads llm.conf (backend binary, args, device)
  -> reads models.conf (model args, profile args)
  -> assembles command (merge order above)
  -> exec
```

1. **`llm serve <model>`** resolves backend and profile, writes state to `current_model`, starts systemd
2. **systemd** executes `service-wrapper.sh`
3. **service-wrapper.sh** reads `current_model` (format: `model_id|backend|profile`)
4. **Command assembled** from binary + backend_args + profile_args + model_args + extra_args + host/port + device
5. **Server binary** runs as systemd service (auto-restart on crash)

### Port allocation

| Type | Default Port | Management |
|------|--------------|------------|
| Main service | 4444 | systemd, persistent |
| Instance 1 | instance_port_start (8081) | background process |
| Instance 2 | instance_port_start + 1 | background process |

## Examples

### CPU-only model (no profile needed)

```ini
[example-cpu]
name="Example 4B CPU"
description="Small text model, CPU only"
backend=cpu
<args>
-m $HOME/models/example-4b-Q4_K_M.gguf \
--ctx-size 8192 \
--threads 4 \
--cache-type-v q8_0 \
--cache-type-k q8_0
</args>
```

### GPU model with profile

```ini
[example-9b]
name="Example 9B"
description="9B model using mem-tight profile"
backend=rocm
profile=mem-tight
<args>
-m $HOME/models/example-9b-Q4_K_S.gguf \
--ctx-size 8192 \
--threads -1 \
--parallel 1
</args>
```

The `mem-tight` profile provides quantized KV cache, flash attention, and sampling defaults. The model only specifies its path, context size, and parallelism.

### Multimodal vision model

```ini
[example-vision]
name="Example 35B Vision"
description="Multimodal model with mmproj"
backend=rocm
profile=high-fidelity
<args>
-m $HOME/models/example-35b-vision-Q4_K_S.gguf \
--mmproj $HOME/models/example-35b-mmproj-BF16.gguf \
--ctx-size 262144 \
--parallel 1 \
--main-gpu 0
</args>
```

### Multi-GPU with manual device override

```ini
[example-122b-multi]
name="Example 122B Multi-GPU"
description="122B model split across two GPUs"
backend=vulkan
profile=mem-tight
<args>
-m $HOME/models/example-122b-Q4_K_XL-00001-of-00003.gguf \
--ctx-size 262144 \
--threads 8 \
--device Vulkan0,Vulkan1 \
--parallel 1 \
--split-mode layer \
--tensor-split 0.7,0.3 \
--n-cpu-moe 21 \
--kv-unified
</args>
```

Because this model specifies `--device Vulkan0,Vulkan1` in its args block, the backend's `device=Vulkan0` is skipped. This is how multi-GPU configs work: include `--device` in the model args and the auto-injection won't touch it.

### vLLM backend

```ini
[example-vllm]
name="Example 27B vLLM"
description="27B model served via vLLM"
backend=vllm
profile=vllm-standard
<args>
$HOME/models/Example-27B-NVFP4 \
--max-model-len 256000 \
--enable-auto-tool-choice \
--tool-call-parser qwen3_xml \
--reasoning-parser qwen3
</args>
```

The vLLM backend sets `binary=vllm` with a venv, injects `serve` as a `backend_arg` prefix, and appends `--served-model-name local` via `extra_args`. The profile adds vLLM-specific flags like `--kv-cache-dtype fp8`.

### Runtime backend override

Any model can be served on a different backend without editing config:

```bash
llm serve example-9b cuda        # Run a rocm model on cuda
llm serve example-9b cpu         # Test on CPU
llm serve example-cpu rocm       # Run a CPU model on GPU
```

## Prune Command

`llm prune` scans `models.conf` for entries that can't run: missing backends, missing binaries, or missing model files.

```bash
llm prune             # Dry run, shows what would be removed
llm prune --force     # Removes invalid entries, saves backup to models.conf.bak
```

Checks performed:
- Model has a `backend=` field
- Backend exists in `llm.conf`
- Backend binary is executable
- Model path (`-m` or positional arg) exists on disk

## Troubleshooting

### Service fails to start

```bash
journalctl --user -u llm.service -n 50
```

1. Verify the backend binary path in `llm.conf` points to an executable
2. Check GPU device name with `vulkaninfo`, `nvidia-smi`, or `rocm-smi`
3. Run `llm list` to see which models have valid backends

### Port already in use

```bash
sudo lsof -i :4444
```

### Model not found

```bash
llm list
```

### Permission denied

```bash
chmod +x $LLM_DIR/launcher.sh $LLM_DIR/service-wrapper.sh
```

### Backend not found

Check that the `[backend.<name>]` section exists in `llm.conf` and the `binary=` path is correct. For venv-based backends, verify the venv path contains `bin/activate`.

## Systemd Integration

The service file uses `%h` for home directory expansion, which systemd resolves to the user's home directory. The service is installed as a **user service** (not system-wide), running without root privileges.

```bash
llm enable    # Start service on user login
llm disable   # Disable
```

## License

Provided as-is for use with llama.cpp (GPLv3).
