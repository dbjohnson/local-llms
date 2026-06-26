#!/usr/bin/env bash

# Setup script for Codex Desktop with local Qwen3.6-27B model
# This installs all dependencies: llama.cpp, bun, opencodex, and configures everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"
SETUP_DIR="${SCRIPT_DIR}/setup"

LLAMA_DIR="${HOME}/.local/llama.cpp"
BIN_DIR="${HOME}/.local/bin"
BUN_DIR="${HOME}/.bun"
CODEX_CONFIG="${HOME}/.codex/config.toml"
OPENCODEX_CONFIG="${HOME}/.opencodex/config.json"
CATALOG="${RUN_DIR}/llama-server-models.json"
MODEL="unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M"
LLAMA_PORT=8080
PROXY_PORT=8082

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[setup]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
log_error() { echo -e "${RED}[setup]${NC} $1"; }
log_step() { echo -e "${BLUE}[setup]${NC} $1"; }

# ─── Step 1: llama.cpp ─────────────────────────────────────────────────────
setup_llama_cpp() {
  log_step "=== Step 1: llama.cpp ==="

  if command -v llama-server >/dev/null 2>&1; then
    log_info "llama-server found: $(which llama-server)"
    # Check if it supports --spec-type (MTP)
    if llama-server --help 2>&1 | grep -- '--spec-type' >/dev/null; then
      log_info "llama-server supports MTP speculative decoding ✓"
      return 0
    else
      log_warn "llama-server found but does NOT support --spec-type"
      log_warn "Rebuilding from source to get MTP support..."
    fi
  fi

  mkdir -p "${LLAMA_DIR}" "${BIN_DIR}"

  if [ -d "${LLAMA_DIR}/.git" ]; then
    log_info "Updating llama.cpp..."
    cd "${LLAMA_DIR}"
    git pull origin main
  else
    log_info "Cloning llama.cpp..."
    git clone https://github.com/ggml-org/llama.cpp.git "${LLAMA_DIR}"
    cd "${LLAMA_DIR}"
  fi

  log_info "Building llama.cpp with Metal GPU acceleration..."
  cmake -B build -DGGML_METAL=ON -DCMAKE_INSTALL_PREFIX="${LLAMA_DIR}"
  cmake --build build --config Release -j$(sysctl -n hw.ncpu)

  # Symlink binaries
  for bin in llama-server llama-cli llama-bench; do
    if [ -f "build/bin/${bin}" ]; then
      ln -sf "${LLAMA_DIR}/build/bin/${bin}" "${BIN_DIR}/${bin}"
      log_info "Linked ${bin} → ${BIN_DIR}/${bin}"
    fi
  done

  # Add to PATH if not already there
  if ! echo "$PATH" | grep -q "${BIN_DIR}"; then
    log_warn "Please add ${BIN_DIR} to your PATH:"
    log_warn "  export PATH=\"${BIN_DIR}:\$PATH\""
    log_warn "(Add this to your ~/.zshrc or ~/.bashrc)"
  fi

  log_info "llama.cpp setup complete ✓"
}

# ─── Step 2: bun (JavaScript runtime) ──────────────────────────────────────
setup_bun() {
  log_step "=== Step 2: bun (JavaScript runtime) ==="

  if [ -x "${BUN_DIR}/bin/bun" ]; then
    log_info "bun already installed: ${BUN_DIR}/bin/bun"
    return 0
  fi

  log_info "Installing bun..."
  curl -fsSL https://bun.sh/install | bash

  if [ -x "${BUN_DIR}/bin/bun" ]; then
    log_info "bun installed successfully ✓"
    log_warn "Please add ${BUN_DIR}/bin to your PATH:"
    log_warn "  export PATH=\"${BUN_DIR}/bin:\$PATH\""
    log_warn "(Add this to your ~/.zshrc or ~/.bashrc)"
  else
    log_error "bun installation failed"
    return 1
  fi
}

# ─── Step 3: opencodex npm package ──────────────────────────────────────────
setup_opencodex() {
  log_step "=== Step 3: opencodex proxy ==="

  # Ensure bun is available
  if [ -x "${BUN_DIR}/bin/bun" ]; then
    export PATH="${BUN_DIR}/bin:${PATH}"
  fi

  if ! command -v npm >/dev/null 2>&1; then
    log_error "npm not found. Please install Node.js (e.g., via Homebrew: brew install node)"
    return 1
  fi

  if npm list -g @bitkyc08/opencodex >/dev/null 2>&1; then
    log_info "opencodex already installed globally ✓"
  else
    log_info "Installing opencodex globally via npm..."
    npm install -g @bitkyc08/opencodex
    log_info "opencodex installed ✓"
  fi

  # Install ocx wrapper if not present
  OCX_PATH="/opt/homebrew/bin/ocx"
  if [ -f "${OCX_PATH}" ]; then
    log_info "ocx wrapper already at ${OCX_PATH}"
  else
    log_info "Creating ocx wrapper at ${OCX_PATH}..."
    # Find the actual cli.ts path
    CLI_TS="$(npm root -g)/@bitkyc08/opencodex/src/cli.ts"
    if [ -f "${CLI_TS}" ]; then
      sudo mkdir -p /opt/homebrew/bin
      sudo tee "${OCX_PATH}" >/dev/null <<EOF
#!/Users/bryan/.bun/bin/bun
import { execFileSync, spawn } from "node:child_process";
import { rmSync } from "node:fs";

const exec = (file, args, opts) => {
  try {
    return execFileSync(file, args, opts);
  } catch (e) {
    throw e;
  }
};

const spawnProcess = (file, args, opts) => {
  const child = spawn(file, args, opts);
  child.on("exit", (code) => {
    process.exit(code ?? 0);
  });
};

const main = async () => {
  const args = process.argv.slice(2);
  const cliPath = "${CLI_TS}";
  spawnProcess("${BUN_DIR}/bin/bun", [cliPath, ...args], {
    stdio: "inherit",
    env: process.env,
  });
};

main();
EOF
      sudo chmod +x "${OCX_PATH}"
      log_info "ocx wrapper created ✓"
    else
      log_warn "Could not find opencodex CLI at ${CLI_TS}"
      log_warn "ocx wrapper not created"
    fi
  fi
}

# ─── Step 4: Model catalog ───────────────────────────────────────────────────
setup_catalog() {
  log_step "=== Step 4: Model catalog ==="

  mkdir -p "${RUN_DIR}"

  cat > "${CATALOG}" <<EOF
{
  "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "client_version": "26.623.31921",
  "models": [
    {
      "slug": "llama-local/${MODEL}",
      "display_name": "llama-local/${MODEL}",
      "description": "Routed via opencodex → llama-local (llamacpp).",
      "shell_type": "shell_command",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 5,
      "base_instructions": "You are a helpful coding assistant.",
      "web_search_tool_type": "text_and_image",
      "supports_search_tool": true,
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Fast responses"},
        {"effort": "medium", "description": "Balanced"},
        {"effort": "high", "description": "Deep reasoning"},
        {"effort": "xhigh", "description": "Maximum reasoning"}
      ],
      "default_reasoning_level": "medium",
      "context_window": 131072,
      "max_context_window": 131072,
      "auto_compact_token_limit": 117964,
      "supports_reasoning_summaries": true,
      "default_reasoning_summary": "none",
      "support_verbosity": true,
      "default_verbosity": "low",
      "apply_patch_tool_type": "freeform",
      "truncation_policy": {
        "mode": "tokens",
        "limit": 10000
      },
      "supports_parallel_tool_calls": true,
      "supports_image_detail_original": false,
      "experimental_supported_tools": [],
      "input_modalities": ["text"],
      "effective_context_window_percent": 95,
      "comp_hash": "opencodex"
    }
  ]
}
EOF

  log_info "Model catalog written to ${CATALOG} ✓"
}

# ─── Step 5: opencodex config ────────────────────────────────────────────────
setup_opencodex_config() {
  log_step "=== Step 5: opencodex proxy config ==="

  mkdir -p "$(dirname "${OPENCODEX_CONFIG}")"

  cat > "${OPENCODEX_CONFIG}" <<EOF
{
  "port": ${PROXY_PORT},
  "defaultProvider": "llama-local",
  "providers": {
    "llama-local": {
      "adapter": "openai-chat",
      "baseUrl": "http://localhost:${LLAMA_PORT}/v1",
      "authMode": "key",
      "apiKey": "",
      "defaultModel": "${MODEL}",
      "modelContextWindows": {
        "${MODEL}": 131072
      }
    }
  }
}
EOF

  log_info "opencodex config written to ${OPENCODEX_CONFIG} ✓"
}

# ─── Step 6: Codex Desktop config ───────────────────────────────────────────
setup_codex_config() {
  log_step "=== Step 6: Codex Desktop config ==="

  mkdir -p "$(dirname "${CODEX_CONFIG}")"

  # Backup existing config
  if [ -f "${CODEX_CONFIG}" ]; then
    cp "${CODEX_CONFIG}" "${CODEX_CONFIG}.backup.$(date +%s)"
    log_info "Backed up existing config"
  fi

  cat > "${CODEX_CONFIG}" <<EOF
model = "llama-local/${MODEL}"
model_provider = "opencodex"
model_catalog_json = "${CATALOG}"

[model_providers.opencodex]
name = "OpenCodex Proxy"
base_url = "http://localhost:${PROXY_PORT}/v1"
wire_api = "responses"
requires_openai_auth = true

[features]
js_repl = false
EOF

  log_info "Codex config written to ${CODEX_CONFIG} ✓"
}

# ─── Step 7: Codex Desktop app ─────────────────────────────────────────────
setup_codex_app() {
  log_step "=== Step 7: Codex Desktop app ==="

  if [ -d "/Applications/Codex.app" ]; then
    log_info "Codex Desktop app found at /Applications/Codex.app ✓"
  else
    log_warn "Codex Desktop app NOT found at /Applications/Codex.app"
    log_warn "Please download it from: https://github.com/openai/codex"
    log_warn "Or install via: brew install --cask codex"
  fi
}

# ─── Step 8: PATH check ────────────────────────────────────────────────────
verify_path() {
  log_step "=== Step 8: PATH verification ==="

  local path_ok=true

  if ! echo "$PATH" | grep -q "${BIN_DIR}"; then
    log_warn "${BIN_DIR} is NOT in your PATH"
    log_warn "Add this to your ~/.zshrc or ~/.bashrc:"
    log_warn "  export PATH=\"${BIN_DIR}:\$PATH\""
    path_ok=false
  else
    log_info "${BIN_DIR} is in PATH ✓"
  fi

  if ! echo "$PATH" | grep -q "${BUN_DIR}/bin"; then
    log_warn "${BUN_DIR}/bin is NOT in your PATH"
    log_warn "Add this to your ~/.zshrc or ~/.bashrc:"
    log_warn "  export PATH=\"${BUN_DIR}/bin:\$PATH\""
    path_ok=false
  else
    log_info "${BUN_DIR}/bin is in PATH ✓"
  fi

  if [ "$path_ok" = false ]; then
    log_warn ""
    log_warn "Some directories are missing from PATH."
    log_warn "You may need to restart your shell or run:"
    log_warn "  source ~/.zshrc"
  fi
}

# ─── Main ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Codex Desktop + Local Qwen3.6-27B Setup Script            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

setup_llama_cpp
setup_bun
setup_opencodex
setup_catalog
setup_opencodex_config
setup_codex_config
setup_codex_app
verify_path

echo ""
log_info "╔══════════════════════════════════════════════════════════════╗"
log_info "║                     Setup Complete!                         ║"
log_info "╚══════════════════════════════════════════════════════════════╝"
echo ""
log_info "To start everything, run:"
log_info "  ./run/codex.sh"
echo ""
log_info "This will:"
log_info "  1. Start llama-server on port ${LLAMA_PORT}"
log_info "  2. Start opencodex proxy on port ${PROXY_PORT}"
log_info "  3. Launch Codex Desktop"
echo ""
log_info "Note: The first time you run, the model will be downloaded from"
log_info "HuggingFace (~18GB for Q4_K_M). This may take a while."
echo ""
