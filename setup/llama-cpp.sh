#!/usr/bin/env bash

# Setup script for llama.cpp on macOS (Apple Silicon)
# Builds with Metal GPU acceleration + FMA instructions
#
# Auto-detection:
#   - Uses performance cores for compilation (faster build)
#   - Enables FMA instructions (M1+/M4 GPU compute optimization)
#   - Embeds Metal shader binary (faster startup)
#
# NOTE: The Homebrew bottle is often outdated and lacks newer flags like
# --spec-type. We build from source to stay current.

set -euo pipefail

INSTALL_DIR="${HOME}/.local/llama.cpp"
BIN_DIR="${HOME}/.local/bin"

# Detect performance cores for faster compilation
# (e.g. M4 Max: 10p cores, M1 Max: 8p cores)
PERF_CORES=$(sysctl -n hw.perflevel.highestp.cores 2>/dev/null || sysctl -n hw.ncpu)

echo "Setting up llama.cpp for Apple Silicon..."
echo "Detected ${PERF_CORES} performance cores for compilation."

# Create directories
mkdir -p "${INSTALL_DIR}" "${BIN_DIR}"

# Clone or update llama.cpp
if [ -d "${INSTALL_DIR}/.git" ]; then
  echo "Updating existing llama.cpp..."
  cd "${INSTALL_DIR}"
  git pull origin master
else
  echo "Cloning llama.cpp..."
  git clone https://github.com/ggml-org/llama.cpp.git "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"
fi

# Build with Metal + FMA + embedded shader library
echo "Building with Metal GPU acceleration (using ${PERF_CORES} performance cores)..."
cmake -B build \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_FMA=ON \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
cmake --build build --config Release --parallel "${PERF_CORES}"

# Symlink binaries to PATH
for bin in llama-server llama-cli llama-bench; do
  if [ -f "build/bin/${bin}" ]; then
    ln -sf "${INSTALL_DIR}/build/bin/${bin}" "${BIN_DIR}/${bin}"
  fi
done

echo ""
echo "llama.cpp installed successfully!"
echo "Binaries linked to: ${BIN_DIR}"
echo ""
echo "Make sure ${BIN_DIR} is in your PATH:"
echo "  export PATH=\"${BIN_DIR}:\$PATH\""
echo ""
echo "You can now run models with:"
echo "  ./run/serve_model.sh [qwen3.6-27b]"
echo ""
echo "New build options:"
echo "  GGML_METAL_FMA=ON         — Enables fused multiply-add (~10-15% throughput boost)"
echo "  GGML_METAL_EMBED_LIBRARY  — Embeds Metal shaders (faster startup)"
echo "  --parallel ${PERF_CORES}    — Compiles using performance cores only"
