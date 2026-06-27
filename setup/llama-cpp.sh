#!/usr/bin/env bash

# Setup script for llama.cpp on macOS (Apple Silicon)
# Builds with Metal GPU acceleration
#
# NOTE: The Homebrew bottle is often outdated (e.g. stable 7480) and lacks
# newer flags like --spec-type. We build from source to stay current.

set -euo pipefail

INSTALL_DIR="${HOME}/.local/llama.cpp"
BIN_DIR="${HOME}/.local/bin"

echo "Setting up llama.cpp for Apple Silicon..."

# Create directories
mkdir -p "${INSTALL_DIR}" "${BIN_DIR}"

# Clone or update llama.cpp
if [ -d "${INSTALL_DIR}/.git" ]; then
  echo "Updating existing llama.cpp..."
  cd "${INSTALL_DIR}"
  git pull origin main
else
  echo "Cloning llama.cpp..."
  git clone https://github.com/ggml-org/llama.cpp.git "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"
fi

# Build with Metal support
echo "Building with Metal GPU acceleration..."
cmake -B build -DGGML_METAL=ON -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
cmake --build build --config Release -j$(sysctl -n hw.ncpu)

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
