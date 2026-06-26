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

# Start llama-server, opencodex proxy, and Codex Desktop (backgrounds by default)
./run/codex.sh

# Stop all services and restore original Codex config
./run/teardown.sh
```

## Scripts

### `run/codex.sh`

Orchestrates the full stack: starts llama-server → opencodex proxy → configures Codex → launches Codex Desktop.

- **Default (background):** Starts all services and detaches. Your terminal is free.
- **`--foreground`:** Blocks in the terminal, waits for Codex to close, then auto-teardowns.

### `run/qwen3.6-27b.sh`

Runs just the Qwen3.6-27B model server via llama.cpp with MTP speculative decoding.

- **Default (background):** Backgrounds the server, writes PID to `/tmp/qwen3.6-27b.pid`.
- **`--foreground`:** Runs in place (useful for debugging).

Environment variables:
- `PORT` — listen port (default: `8080`)
- `CONTEXT` — context size (default: `32768`)

### `run/teardown.sh`

Stops all running local LLM services and optionally restores the original Codex config.

| Flag | Action |
|---|---|
| *(none)* | Stop services **and** restore config |
| `--no-config` | Stop services only, leave config as-is |
| `--config` | Restore config only, don't kill anything |
| `--status` | Show what's running and available backups |

Detects services by:
- **Port scanning** (8080 = llama-server, 8082 = opencodex)
- **PID files** (`/tmp/qwen3.6-27b.pid`, `/tmp/llama-server.pid`, `/tmp/opencodex.pid`)

## Workflow

```bash
# Fresh start (stops old services, starts new ones)
./run/teardown.sh && ./run/codex.sh

# Or just start (skips services already running)
./run/codex.sh

# Check what's running
./run/teardown.sh --status

# Stop and restore original Codex config
./run/teardown.sh
```

## Models

- Qwen3.6-27B (MTP speculative decoding) via llama.cpp
