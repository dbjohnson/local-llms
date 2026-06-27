#!/usr/bin/env bash

# Run Qwen3.6-35B-A3B (MoE) — optimized for Apple Silicon (MacBook Pro M4)
# Default: backgrounds itself. Use --foreground to run in place.

set -euo pipefail

MODEL="${MODEL:-unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M}"
PORT="${PORT:-8080}"
CONTEXT_SIZE="${CONTEXT:-65536}"

# Parse flags
FOREGROUND=false
for arg in "$@"; do
  [[ "$arg" == "--foreground" || "$arg" == "-f" ]] && FOREGROUND=true
done

# Identify this process for teardown
PID_FILE="/tmp/qwen3.6-35b-a3b.pid"
LOG_FILE="/tmp/qwen3.6-35b-a3b.log"

echo "Starting Qwen3.6-35B-A3B (MoE)..."
echo "Model: $MODEL"
echo "Port: $PORT"
echo "Context size: $CONTEXT_SIZE"
echo ""

CMD=(llama-server \
  -hf "${MODEL}" \
  -c "${CONTEXT_SIZE}" \
  --port "${PORT}")

if [[ "$FOREGROUND" == "true" ]]; then
  echo "Running in foreground..."
  exec "${CMD[@]}"
else
  echo "Running in background. Use --foreground to run in place."
  echo "  To stop: ./run/teardown.sh"
  echo ""
  nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
  echo $! > "${PID_FILE}"
  echo "Started llama-server (PID $!) → ${PID_FILE}"
fi
