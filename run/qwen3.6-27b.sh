#!/usr/bin/env bash

# Run Qwen3.6-27B with MTP speculative decoding
# Optimized for Apple Silicon (MacBook Pro M4)

set -euo pipefail

MODEL="unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M"
PORT="${PORT:-8080}"
CONTEXT_SIZE="${CONTEXT:-32768}"

echo "Starting Qwen3.6-27B with MTP speculative decoding..."
echo "Port: $PORT"
echo "Context size: $CONTEXT_SIZE"
echo ""

# Verify the llama-server binary supports --spec-type
# Note: llama-server --help triggers Metal init which prints to stderr and is
# slow. Using grep -q can cause a SIGPIPE (exit 141) under set -o pipefail
# because grep exits early after finding the match while the producer is still
# writing. We use grep without -q and redirect to /dev/null to avoid this.
if ! llama-server --help 2>&1 | grep -- '--spec-type' >/dev/null; then
  echo "ERROR: Your llama-server binary does not support --spec-type." >&2
  echo "       MTP speculative decoding requires a recent build of llama.cpp (>= b9196)." >&2
  echo "       Please run the setup script to build from source:" >&2
  echo "         ./setup/llama-cpp.sh" >&2
  exit 1
fi

llama-server \
  -hf "${MODEL}" \
  --spec-type draft-mtp \
  --spec-draft-n-max 2 \
  -c "${CONTEXT_SIZE}" \
  --port "${PORT}"
