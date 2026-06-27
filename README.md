# Local LLMs

Scripts for running LLMs locally using llama.cpp and other engines.

## Requirements

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- macOS (Apple Silicon optimized)

## Structure

- `setup/` - Installation and setup scripts
- `run/` - Model-specific run scripts, orchestration, and teardown

## Quick Start

```bash
# One-time setup (install dependencies, configure everything)
./setup.sh

# For Codex Desktop:
./run/codex.sh              # start llama-server + proxy + Codex (backgrounds)
./run/teardown.sh           # stop all services and restore configs

# For opencode:
./run/opencode.sh --start   # start llama-server + configure opencode
./run/teardown.sh           # stop services and restore configs
```

## Model Swapping via Environment Variables

All orchestration scripts support swapping the model and server script via environment variables:

| Variable | Default | Description |
|---|---|---|
| `MODEL` | `unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M` | HuggingFace model ID (with quant tag) |
| `LLAMA_SCRIPT` | `./run/qwen3.6-27b.sh` | Server script to start |
| `PORT` | `8080` | llama-server listen port |

### Examples

```bash
# Use the Qwen3.6-35B-A3B MoE coding model with Codex
MODEL=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M \
  LLAMA_SCRIPT=./run/qwen3.6-35b-a3b.sh \
  ./run/codex.sh

# Use the Qwen3.6-35B-A3B MoE model with opencode
MODEL=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M \
  LLAMA_SCRIPT=./run/qwen3.6-35b-a3b.sh \
  ./run/opencode.sh --start

# Use a different quantization of the dense 27B model
MODEL=unsloth/Qwen3.6-27B-MTP-GGUF:Q5_K_M ./run/codex.sh
```

## Monitoring Logs

Every model script writes its output to `/tmp/<script-name>.log` and its PID to `/tmp/<script-name>.pid`. The orchestration scripts (`codex.sh`, `opencode.sh`) use `/tmp/llama-server.log` and `/tmp/llama-server-opencode.log` respectively.

| Script | Log file | PID file |
|---|---|---|
| `run/<model>.sh` | `/tmp/<model>.log` | `/tmp/<model>.pid` |
| `run/codex.sh` (server it starts) | `/tmp/llama-server.log` | `/tmp/llama-server.pid` |
| `run/opencode.sh` (server it starts) | `/tmp/llama-server-opencode.log` | `/tmp/llama-server-opencode.pid` |
| `run/opencodex` proxy | `/tmp/opencodex.log` | `/tmp/opencodex.pid` |

### Examples

```bash
# Tail the log of whichever model server you started
# (replace <model> with the script name, e.g. qwen3.6-27b or qwen3.6-35b-a3b)
tail -f /tmp/<model>.log

# Show PID + tail log in one go
cat /tmp/<model>.pid && tail -f /tmp/<model>.log

# Watch all local LLM logs at once
tail -f /tmp/qwen3.6-27b.log /tmp/qwen3.6-35b-a3b.log /tmp/llama-server.log /tmp/llama-server-opencode.log /tmp/opencodex.log

# Filter for tokens / errors
tail -f /tmp/<model>.log | grep -E "(slot|prompt|token|error|load)"
```

## Scripts

### `run/qwen3.6-27b.sh`

Runs the Qwen3.6-27B dense model server via llama.cpp with MTP speculative decoding.

- **Default (background):** Backgrounds the server, writes PID to `/tmp/qwen3.6-27b.pid`.
- **`--foreground`:** Runs in place (useful for debugging).

Environment variables:
- `MODEL` — model ID (default: `unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M`)
- `PORT` — listen port (default: `8080`)
- `CONTEXT` — context size (default: `65536`)

### `run/qwen3.6-35b-a3b.sh`

Runs the **Qwen3.6-35B-A3B** MoE model server via llama.cpp.
This is the latest Qwen MoE coding model (35B total / 3B active parameters).
At Q4_K_M it needs ~20 GB RAM and excels at agentic coding workflows.

- **Default (background):** Backgrounds the server, writes PID to `/tmp/qwen3.6-35b-a3b.pid`.
- **`--foreground`:** Runs in place (useful for debugging).

Environment variables:
- `MODEL` — model ID (default: `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`)
- `PORT` — listen port (default: `8080`)
- `CONTEXT` — context size (default: `65536`)

### `run/codex.sh`

Orchestrates the full stack for Codex Desktop: starts llama-server → opencodex proxy → configures Codex → launches Codex Desktop.

- **Default (background):** Starts all services and detaches. Your terminal is free.
- **`--foreground`:** Blocks in the terminal, waits for Codex to close, then auto-teardowns.

Environment variables:
- `MODEL` — model ID passed to the catalog and proxy config
- `LLAMA_SCRIPT` — which server script to execute
- `LLAMA_PORT` — llama-server port (default: `8080`)
- `PROXY_PORT` — opencodex proxy port (default: `8082`)

### `run/opencode.sh`

Configures [opencode](https://github.com/opencode-ai/opencode) to use llama-server as a local OpenAI-compatible provider.

- **Default:** Configures opencode only (assumes llama-server is already running).
- **`--start`:** Starts llama-server on port 8080 and configures opencode.
- **`--foreground`:** Starts llama-server in foreground (for debugging).
- **`--restore`:** Removes the `llama-local` provider from opencode config.

Environment variables:
- `MODEL` — model ID registered in opencode config
- `LLAMA_SCRIPT` — which server script to start with `--start`/`--foreground`
- `LLAMA_PORT` — llama-server port (default: `8080`)

After running, launch opencode with:
```bash
opencode -m llama-local/unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M
```

### `run/teardown.sh`

Stops all running local LLM services and optionally restores original configs.

| Flag | Action |
|---|---|
| *(none)* | Stop services **and** restore Codex + opencode configs |
| `--no-config` | Stop services only, leave configs as-is |
| `--config` | Restore configs only, don't kill anything |
| `--status` | Show what's running and available backups |

Detects services by:
- **Port scanning** (8080 = llama-server, 8082 = opencodex)
- **PID files** (`/tmp/qwen3.6-27b.pid`, `/tmp/qwen3.6-35b-a3b.pid`, `/tmp/llama-server.pid`, `/tmp/llama-server-opencode.pid`, `/tmp/opencodex.pid`)

## Workflows

```bash
# Codex Desktop with dense 27B model
./run/teardown.sh && ./run/codex.sh     # fresh start
./run/codex.sh                          # start (skips if services are running)

# Codex Desktop with MoE 35B-A3B model
MODEL=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M LLAMA_SCRIPT=./run/qwen3.6-35b-a3b.sh ./run/codex.sh

# opencode with dense 27B model
./run/opencode.sh --start
opencode -m llama-local/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M

# opencode with MoE 35B-A3B model
MODEL=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M LLAMA_SCRIPT=./run/qwen3.6-35b-a3b.sh ./run/opencode.sh --start
opencode -m llama-local/unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M

# Clean up
./run/teardown.sh && ./run/opencode.sh --restore

# Check what's running
./run/teardown.sh --status
```

## Models

| Model | Type | Size (Q4_K_M) | Best For |
|---|---|---|---|
| Qwen3.6-27B (MTP) | Dense | ~16 GB | Consistent throughput, general coding |
| Qwen3.6-35B-A3B | MoE | ~20 GB | Agentic coding, tool use, function calling |

Both are served via llama.cpp with Metal GPU acceleration on Apple Silicon.
