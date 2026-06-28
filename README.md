# Local LLMs

Scripts for running LLMs locally using llama.cpp and other engines.

## Requirements

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- macOS (Apple Silicon optimized)

## Structure

- `setup.sh` — One-time root-level setup script (install dependencies, configure everything)
- `setup/` — Additional setup scripts (e.g. `llama-cpp.sh` to build llama.cpp from source)
- `run/` - Model-specific run scripts, orchestration, and teardown
- `run/openwebui.sh` — Configure Open WebUI to use a local llama-server

## Quick Start

```bash
# One-time setup (install dependencies, configure everything)
./setup.sh

# For Codex Desktop:
./run/codex.sh              # OpenRouter via proxy (requires OPENROUTER_API_KEY)
./run/codex.sh --local      # local model via proxy
./run/teardown.sh           # stop all services and restore configs

# For Codex with local DeepSeek-R1-Distill-Qwen-32B:
MODEL_CHOICE=deepseek-r1-32b ./run/codex.sh --local
```

## Model Selection

The unified `serve_model.sh` script handles model selection via a positional argument or `MODEL_CHOICE` environment variable.

```bash
# Default: Qwen3.6-35B-A3B (MoE)
./run/serve_model.sh

# Qwen3.6-27B with MTP speculative decoding
./run/serve_model.sh qwen3.6-27b

# Or use MODEL_CHOICE env var
MODEL_CHOICE=qwen3.6-27b ./run/serve_model.sh

# DeepSeek-R1-Distill-Qwen-32B
MODEL_CHOICE=deepseek-r1-32b ./run/serve_model.sh
```

### Available Models

| Model Choice | Model | Type | Size (Q4_K_M) | Best For |
|---|---|---|---|---|
| `qwen3.6-35b-a3b` | Qwen3.6-35B-A3B | MoE | ~20 GB | Agentic coding, tool use, function calling |
| `qwen3.6-27b` | Qwen3.6-27B (MTP) | Dense | ~16 GB | Consistent throughput, general coding |
| `deepseek-r1-32b` | DeepSeek-R1-Distill-Qwen-32B | Dense | ~19 GB | Reasoning, math, complex tasks |

### Overriding the Model

**OpenRouter mode (default):**
```bash
# Use OpenRouter with default 35B-A3B model
./run/codex.sh

# Use OpenRouter with custom model
OPENROUTER_MODEL=openai/gpt-4o ./run/codex.sh
```

**Local mode:**
```bash
# Use 35B-A3B with Codex (default)
./run/codex.sh --local

# Use 27B with MTP
MODEL_CHOICE=qwen3.6-27b ./run/codex.sh --local

# Custom model via MODEL env var
MODEL=my-org/my-model:Q5_K_M ./run/codex.sh --local

# Custom model + model choice for serve_model.sh
MODEL_CHOICE=qwen3.6-27b MODEL=my-org/my-model:Q4_K_M ./run/codex.sh --local

# Use DeepSeek-R1-Distill-Qwen-32B with Codex
MODEL_CHOICE=deepseek-r1-32b ./run/codex.sh --local
```

## Monitoring Logs

All model servers share the same log and PID files (only one runs at a time):

| File | Path |
|---|---|
| Log | `/tmp/llama-server.log` |
| PID | `/tmp/llama-server.pid` |

### Examples

```bash
# Tail the log
tail -f /tmp/llama-server.log

# Show PID
cat /tmp/llama-server.pid

# Watch all local LLM logs at once
tail -f /tmp/llama-server.log /tmp/llama-server-opencode.log /tmp/opencodex.log

# Filter for tokens / errors
tail -f /tmp/llama-server.log | grep -E "(slot|prompt|token|error|load)"
```


## Scripts

### `run/serve_model.sh`

Unified model launcher for all local LLMs. Supports Qwen3.6-35B-A3B (MoE), Qwen3.6-27B (MTP), and DeepSeek-R1-Distill-Qwen-32B.

- **Default (background):** Backgrounds the server, writes PID to model-specific file.
- **`--foreground`:** Runs in place (useful for debugging).

Arguments:
- No argument → Qwen3.6-35B-A3B (default)
- `qwen3.6-27b` → Qwen3.6-27B with MTP speculative decoding
- `deepseek-r1-32b` → DeepSeek-R1-Distill-Qwen-32B

Environment variables:
- `MODEL` — HuggingFace model ID (e.g. `org/model:quant`)
- `PORT` — listen port (default: `8080`)
- `CONTEXT` — context size (default: `65536`)
- `MODEL_CHOICE` — model identifier (overrides positional arg)

### `run/codex.sh`

Orchestrates the full stack for Codex Desktop: starts llama-server → opencodex proxy → configures Codex → launches Codex Desktop.

**Modes:**
- **Default (OpenRouter):** Uses OpenRouter API via opencodex proxy (requires `OPENROUTER_API_KEY`)
- **`--local`:** Uses a local llama-server + opencodex proxy

**Flags:**
- **Default (background):** Starts all services and detaches. Your terminal is free.
- **`--foreground`:** Blocks in the terminal, waits for Codex to close, then auto-teardowns.

Environment variables:
- **OpenRouter mode:**
  - `OPENROUTER_API_KEY` — your OpenRouter API key (required)
  - `OPENROUTER_MODEL` — model slug (default: `qwen/qwen3.6-35b-a3b`)
  - `PROXY_PORT` — opencodex proxy port (default: `8082`)
- **Local mode:**
  - `MODEL` — HuggingFace model ID (default: `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`)
  - `LLAMA_SCRIPT` — which server script to execute (default: `./run/serve_model.sh`)
  - `LLAMA_PORT` — llama-server port (default: `8080`)
  - `PROXY_PORT` — opencodex proxy port (default: `8082`)
  - `MODEL_CHOICE` — model identifier for `serve_model.sh`

### `run/opencode.sh`

Configures [opencode](https://github.com/opencode-ai/opencode) to use llama-server as a local OpenAI-compatible provider.

- **Default:** Configures opencode only (assumes llama-server is already running).
- **`--start`:** Starts llama-server on port 8080 and configures opencode.
- **`--foreground`:** Starts llama-server in foreground (for debugging).
- **`--restore`:** Removes the `llama-local` provider from opencode config.

Environment variables:
- `MODEL` — HuggingFace model ID registered in opencode config (default: `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`)
- `LLAMA_SCRIPT` — which server script to start with `--start`/`--foreground`
- `LLAMA_PORT` — llama-server port (default: `8080`)
- `MODEL_CHOICE` — model identifier for `serve_model.sh` (default: `qwen3.6-27b`)

> **Note:** When using `--start` or `--foreground`, opencode.sh defaults to `qwen3.6-27b` for the llama-server (`MODEL_CHOICE`).
> The `MODEL` env var controls the model ID registered in opencode's config and should match the running server.

After running, launch opencode with:
```bash
opencode -m llama-local/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M
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
- **PID files** (`/tmp/llama-server.pid`, `/tmp/llama-server-opencode.pid`, `/tmp/opencodex.pid`)

### `run/openwebui.sh`

Configures [Open WebUI](https://github.com/open-webui/open-webui) to use llama-server as a local provider.

- **Default (background):** Starts llama-server and configures Open WebUI settings.
- **`--foreground`:** Runs llama-server in the foreground.

Environment variables:
- `MODEL` — HuggingFace model ID (default: `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`)
- `LLAMA_PORT` — llama-server port (default: `8080`)

## Workflows

```bash
# Codex Desktop with OpenRouter (default 35B-A3B model)
export OPENROUTER_API_KEY="sk-or-..."
./run/teardown.sh && ./run/codex.sh     # fresh start
./run/codex.sh                          # start (skips if services are running)

# Codex Desktop with OpenRouter + custom model
OPENROUTER_MODEL=openai/gpt-4o ./run/codex.sh

# Codex Desktop with local 35B-A3B model
./run/codex.sh --local

# Codex Desktop with local 27B model
MODEL_CHOICE=qwen3.6-27b ./run/codex.sh --local

# opencode with local model (35B-A3B)
MODEL_CHOICE=qwen3.6-35b-a3b MODEL=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M ./run/opencode.sh --start
opencode -m llama-local/unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M

# opencode with 27B model
MODEL_CHOICE=qwen3.6-27b MODEL=unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M ./run/opencode.sh --start
opencode -m llama-local/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M

# Clean up
./run/teardown.sh && ./run/opencode.sh --restore

# Check what's running
./run/teardown.sh --status

# Codex with local DeepSeek-R1-Distill-Qwen-32B
MODEL_CHOICE=deepseek-r1-32b ./run/codex.sh --local

# opencode with local DeepSeek-R1-Distill-Qwen-32B
MODEL_CHOICE=deepseek-r1-32b MODEL=unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF:Q4_K_M ./run/opencode.sh --start
opencode -m llama-local/unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF:Q4_K_M
```
