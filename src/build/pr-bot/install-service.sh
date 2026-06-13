#!/usr/bin/env bash
set -euo pipefail

# install-service.sh — Install PR Bot as an OS-native service.
# Thin wrapper around shared install-service-common.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOT_NAME="pr-bot"
STATE_DIR="$SCRIPT_DIR/.pr-bot-state"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SECRETS_FILE="$SCRIPT_DIR/.secrets.env"
BUILD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$STATE_DIR"

# shellcheck source=../install-service-common.sh
source "$BUILD_DIR/install-service-common.sh"

install_service "${1:-install}"
