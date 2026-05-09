# Installation Guide

## Prerequisites

- **llama.cpp builds** — One or more builds of [llama.cpp](https://github.com/ggml-org/llama.cpp) compiled for your hardware. Each backend in `llm.conf` points to its own `llama-server` binary. Common targets:
  - **Vulkan** — Any GPU with Vulkan support
  - **ROCm** — AMD GPUs
  - **CUDA** — NVIDIA GPUs
  - **CPU** — `ik_llama.cpp` or standard llama.cpp CPU build
- **GGUF model files** — Quantized models in GGUF format (or use HuggingFace auto-download)
- **bash** — Shell for the launcher scripts
- **systemd** — For service management (user-session)

## Clone and Setup

```bash
git clone https://github.com/Zorgonatis/llm-manager.git ~/llm-manager
chmod +x ~/llm-manager/launcher.sh ~/llm-manager/service-wrapper.sh
ln -s ~/llm-manager/launcher.sh ~/.local/bin/llm

# Ensure ~/.local/bin is in PATH
# Fish:
echo 'set -gx PATH $PATH ~/.local/bin' >> ~/.config/fish/config.fish
# Bash:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## Prepare llama.cpp Builds

Each backend in `llm.conf` needs a path to its `llama-server` binary. Organise them however you like:

```
/data-fast/apps/llama.cpp/llama-server                    # CPU
/data-fast/apps/llama.cpp/install-rocm/bin/llama-server   # ROCm
/data-fast/apps/llama.cpp/install-cuda/bin/llama-server   # CUDA
/data-fast/apps/llama.cpp/install-vulkan/bin/llama-server # Vulkan
```

Build from source or use prebuilt releases. Note the path to each one for the next step.

## Configure Backends (`llm.conf`)

Backends are the bridge between a model and a specific llama.cpp build. Define them in `llm.conf`:

```ini
[backend.rocm]
binary=/data-fast/apps/llama.cpp/install-rocm/bin/llama-server
device=ROCm0
<extra_args>
--alias local
</extra_args>

[backend.cpu]
binary=/data-fast/apps/llama.cpp/llama-server
<extra_args>
--alias local
</extra_args>
```

The `device=` field is optional. When set, the manager injects `--device <value>` at launch time automatically. If a model already includes `--device` in its own args (e.g. multi-GPU setups), auto-injection is skipped for that model.

For vLLM, the backend uses `venv=` to activate a virtualenv and `backend_args` for subcommands:

```ini
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

## Add a Model (`models.conf`)

A model entry needs a `backend=` reference (pointing to a `[backend.*]` section in `llm.conf`) and an `<args>` block with raw CLI flags.

**Simple model (no profile):**

```ini
[example-cpu]
name="Example 4B CPU"
description="Small text model, CPU only"
backend=cpu
<args>
-m $HOME/.llm/models/example/example-4b-Q4_K_M.gguf \
--ctx-size 8192 \
--threads 4 \
--cache-type-v q8_0 --cache-type-k q8_0
</args>
```

**Model with a profile:**

```ini
[example-9b]
name="Example 9B"
description="9B model, memory-tuned"
backend=rocm
profile=mem-tight
<args>
-m $HOME/.llm/models/example/example-9b-Q4_K_S.gguf \
--ctx-size 8192 \
--threads -1 \
--parallel 1
</args>
```

The `<args>` block is raw CLI flags. Use `\` for line continuation. Any flag the server binary supports can go here. For HuggingFace auto-download, use `--hf-repo` and `--hf-file` instead of `-m`.

## Profiles

Profiles are reusable `<args>` blocks that models inherit. Define them at the top of `models.conf`:

```ini
[profile.mem-tight]
# Quantized KV cache, flash attention, no mmap
<args>
--cache-type-v q8_0 --cache-type-k q8_0 \
--flash-attn auto --jinja --swa-full --no-mmap \
--gpu-layers 999 --temp 0.6 --min-p 0.0 --top-p 0.95 --top-k 20
</args>

[profile.high-fidelity]
# Full precision KV, higher quality sampling
<args>
--flash-attn auto --jinja --swa-full \
--gpu-layers 999 --temp 1.0 --top-p 0.95
</args>
```

A model sets `profile=<name>` to pull in those shared flags. Model args are merged last, so they override anything the profile sets. The full merge order:

```
backend_args → profile_args → model_args → extra_args
```

## Start an Instance (Temporary)

Run a model as a background process for testing:

```bash
llm start my-model

# Custom port:
llm start my-model --port 8082

# Override backend at runtime:
llm start my-model cuda

# Override profile and backend:
llm start my-model mem-tight cuda
```

```bash
llm status    # check running instances
llm stop      # stop the instance
```

## Run as a Persistent Service

Use `llm serve` to run the model as a systemd user service with auto-restart:

```bash
llm serve my-model

# Override backend at runtime:
llm serve my-model rocm

# Override profile and backend:
llm serve my-model mem-tight rocm
```

This installs the systemd unit, writes the model selection, and starts the service on port 4444 (configurable in `llm.conf`).

```bash
llm status            # service status
llm logs              # follow logs
llm restart other-model  # switch models
llm stop service      # stop the service
llm enable            # start on boot
```

## Configuration Reference

### `llm.conf`

| Variable | Default | Description |
|----------|---------|-------------|
| `models_dir` | `$llm_dir/models` | GGUF model files directory |
| `service_host` | `0.0.0.0` | Host binding for services |
| `service_port` | `4444` | Persistent service port |
| `instance_port_start` | `8081` | First instance port |

**Backend block `[backend.<name>]`:**

| Field | Required | Description |
|-------|----------|-------------|
| `binary` | Yes | Path to the server executable |
| `venv` | No | Virtualenv to activate before running |
| `device` | No | GPU device string, auto-injected as `--device` |
| `<backend_args>` | No | Launch prefix/subcommands (prepended) |
| `<extra_args>` | No | Trailing args (appended last) |

### `models.conf`

**Model block `[<model-name>]`:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Display name |
| `description` | No | Short description |
| `backend` | Yes | Backend name from `llm.conf` |
| `profile` | No | Profile name to inherit shared flags |
| `<args>` | Yes | Raw CLI flags for the server binary |

**Profile block `[profile.<name>]`:**

| Field | Required | Description |
|-------|----------|-------------|
| `<args>` | Yes | Shared CLI flags inherited by models using this profile |
