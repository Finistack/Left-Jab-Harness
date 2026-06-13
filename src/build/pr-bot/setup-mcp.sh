#!/usr/bin/env bash
# setup-mcp.sh — Ensures token-savior-recall MCP is installed in a portable venv.
# Idempotent — safe to call on every bot startup.
# Outputs: path to the token-savior binary on success, exits non-zero on failure.
set -euo pipefail

VENV_DIR="${TOKEN_SAVIOR_VENV:-$HOME/.local/share/token-savior-venv}"

install_token_savior() {
  if [ ! -d "$VENV_DIR" ]; then
    echo "[setup-mcp] Creating venv at $VENV_DIR..." >&2
    python3 -m venv "$VENV_DIR"
  fi

  local current_version
  current_version=$("$VENV_DIR/bin/pip" show token-savior-recall 2>/dev/null | awk '/^Version:/{print $2}') || true

  if [ -z "$current_version" ]; then
    echo "[setup-mcp] Installing token-savior-recall..." >&2
    "$VENV_DIR/bin/pip" install -q token-savior-recall
  fi

  # Verify the binary exists
  if [ ! -x "$VENV_DIR/bin/token-savior" ]; then
    echo "[setup-mcp] ERROR: token-savior binary not found after install" >&2
    return 1
  fi

  echo "$VENV_DIR/bin/token-savior"
}

install_token_savior
