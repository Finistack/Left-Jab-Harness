#!/usr/bin/env bash
# logging.sh — Structured logging for all Finistack bots.
# Source this file to get consistent log formatting for bot-doctor detection.
#
# Log format: [YYYY-MM-DD HH:MM:SS] LEVEL EMOJI  message [key=value ...]
#
# Usage:
#   source "$(dirname "$0")/../shared/logging.sh"
#   LOG_COMPONENT="pr-bot"   # set before calling log functions
#   log_info "PR #1246 completed successfully"
#   log_warn "API rate limited, retrying" "attempt=2"
#   log_error "Claude timeout after 600s" "pr=1246"
#   log_fatal "ADO PAT expired, all auth failing"
#   log_skip "Duplicate ntfy message" "id=abc123"
#   log_lock "Acquired lease" "pr=1246 host=build-host-1 expires=1800s"

LOG_COMPONENT="${LOG_COMPONENT:-bot}"
LOG_HOSTNAME="${LOG_HOSTNAME:-$(hostname -s 2>/dev/null || echo 'unknown')}"

_log_fmt() {
  local level="$1" emoji="$2"
  shift 2
  local message="$1"
  shift
  local kvpairs=""
  [ $# -gt 0 ] && kvpairs=" [$*]"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${level} ${emoji}  ${message}${kvpairs}"
}

log_info()  { _log_fmt "INFO"  "✅" "$@"; }
log_warn()  { _log_fmt "WARN"  "\u26a0\ufe0f" "$@"; }
log_error() { _log_fmt "ERROR" "\u274c" "$@"; }
log_fatal() { _log_fmt "FATAL" "\U0001F480" "$@"; }
log_skip()  { _log_fmt "INFO"  "\u23ed\ufe0f" "$@"; }
log_lock()  { _log_fmt "INFO"  "\U0001F512" "$@"; }

# Convenience: legacy log() function that maps to INFO with custom emoji
# Many existing scripts use: log "emoji message"
# This wrapper preserves backward compatibility
log_compat() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LOG_COMPONENT}@${LOG_HOSTNAME}] $*"; }
