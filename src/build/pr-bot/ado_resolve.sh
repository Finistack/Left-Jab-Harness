#!/usr/bin/env bash
set -euo pipefail

# ado_resolve.sh — Resolve PR threads via ADO REST API
# Usage: ado_resolve.sh <PR_ID> <REPO_ID> <THREAD_IDS_CSV>

VERBOSE="${VERBOSE:-false}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../shared/ado_api.sh"

log() { echo "[$(date '+%H:%M:%S')] [resolver] $*"; }
debug() { [[ "$VERBOSE" == "true" ]] && log "[debug] $*"; }

PR_ID="$1"
REPO_ID="$2"
THREAD_IDS_CSV="$3"

ADO_BASE="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis"

IFS=',' read -ra THREAD_IDS <<< "$THREAD_IDS_CSV"

for THREAD_ID in "${THREAD_IDS[@]}"; do
  [ -z "$THREAD_ID" ] && continue

  log "  Resolving thread $THREAD_ID on PR #${PR_ID}..."

  RESOLVE_URL="${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}/threads/${THREAD_ID}?api-version=7.1"
  if HTTP_CODE=$(ado_patch "$RESOLVE_URL" '{"status":"fixed"}'); then
    log "  ✅ Thread $THREAD_ID resolved (fixed)"
  else
    log "  ⚠️  Thread $THREAD_ID could not be resolved"
  fi
done
