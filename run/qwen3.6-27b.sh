#!/usr/bin/env bash

# Run Qwen3.6-27B with MTP speculative decoding
# Optimized for Apple Silicon (MacBook Pro M4)

set -euo pipefail

MODEL="ggml-org/Qwen3.6-27B-MTP-GGUF"
PORT="${PORT:-8080}"
CONTEXT_SIZE="${CONTEXT:-8192}"

echo "Starting Qwen3.6-27B with MTP speculative decoding..."
echo "Port: $PORT"
echo "Context size: $CONTEXT_SIZE"
echo ""

llama-server \
  -hf "${MODEL}" \
  --spec-type draft-mtp \
  --spec-draft-n-max 2 \
  -c "${CONTEXT_SIZE}" \
  --port "${PORT}"
