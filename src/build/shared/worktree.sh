#!/usr/bin/env bash
# worktree.sh — Shared git worktree management for all Finistack bots.
# Source this file to get worktree create/cleanup/prune helpers.
#
# Usage:
#   source "$(dirname "$0")/../shared/worktree.sh"
#   WORK_DIR=$(create_bot_worktree "$REPO_ROOT" "$WORKTREE_DIR" "pr-123" "$SOURCE_BRANCH")
#   cleanup_bot_worktree "$REPO_ROOT" "$WORK_DIR"
#   prune_stale_worktrees "$REPO_ROOT" "$WORKTREE_DIR" 86400

# Create a worktree for bot processing.
# Usage: create_bot_worktree <repo_root> <worktree_base_dir> <worktree_name> <source_branch> [base_ref]
# Outputs: the worktree directory path
# Returns: 0 on success, 1 on failure
create_bot_worktree() {
  local repo_root="$1"
  local worktree_base="$2"
  local wt_name="$3"
  local source_branch="$4"
  local base_ref="${5:-origin/$source_branch}"

  local work_dir="${worktree_base}/${wt_name}"

  # Remove stale worktree if it exists from a previous run
  if [ -d "$work_dir" ]; then
    git -C "$repo_root" worktree remove --force "$work_dir" 2>/dev/null || {
      rm -rf "$work_dir"
      git -C "$repo_root" worktree prune 2>/dev/null || true
    }
  fi

  # Fetch required branches. -c gc.auto=0: never let a fetch fork a background
  # git-gc (on macOS that child is SIGKILL'd by Launch-Constraint codesigning).
  git -C "$repo_root" -c gc.auto=0 fetch origin main 2>/dev/null || true
  if [ "$source_branch" != "main" ]; then
    git -C "$repo_root" -c gc.auto=0 fetch origin "$source_branch" 2>/dev/null || true
  fi

  # Create worktree in detached HEAD mode, then checkout the branch.
  if ! git -C "$repo_root" worktree add --detach "$work_dir" "$base_ref" 2>&1; then
    echo "Failed to create worktree at ${work_dir}" >&2
    return 1
  fi

  # Create a local tracking branch inside the worktree.
  # Use -B to force-update if the branch already exists.
  if ! git -C "$work_dir" checkout -B "$source_branch" "$base_ref" 2>&1; then
    # Branch might be checked out elsewhere — use a temp branch
    local temp_branch="bot-wt/${wt_name}"
    if ! git -C "$work_dir" checkout -B "$temp_branch" "$base_ref" 2>&1; then
      echo "Failed to create branch in worktree, aborting" >&2
      return 1
    fi
    # Configure push to target the real remote branch
    git -C "$work_dir" config "branch.${temp_branch}.remote" origin
    git -C "$work_dir" config "branch.${temp_branch}.merge" "refs/heads/${source_branch}"
    git -C "$work_dir" config --worktree push.default upstream 2>/dev/null \
      || git -C "$work_dir" config --local push.default upstream
  fi

  echo "$work_dir"
  return 0
}

# Remove a worktree. Handles git worktree remove failure with rm -rf fallback.
# Usage: cleanup_bot_worktree <repo_root> <work_dir>
cleanup_bot_worktree() {
  local repo_root="$1"
  local work_dir="$2"

  [ -z "$work_dir" ] && return 0
  [ ! -d "$work_dir" ] && return 0

  git -C "$repo_root" worktree remove --force "$work_dir" 2>/dev/null || {
    rm -rf "$work_dir"
    git -C "$repo_root" worktree prune 2>/dev/null || true
  }
}

# Prune stale worktrees older than a threshold.
# Usage: prune_stale_worktrees <repo_root> <worktree_base_dir> [max_age_seconds]
prune_stale_worktrees() {
  local repo_root="$1"
  local worktree_base="$2"
  local max_age="${3:-86400}"  # default 24 hours
  local now
  now=$(date +%s)

  [ ! -d "$worktree_base" ] && return 0

  local stale_count=0
  for wt_dir in "$worktree_base"/*/; do
    [ ! -d "$wt_dir" ] && continue
    local wt_mtime
    wt_mtime=$(stat -c '%Y' "$wt_dir" 2>/dev/null || stat -f '%m' "$wt_dir" 2>/dev/null || echo "$now")
    local age=$((now - wt_mtime))
    if [ "$age" -gt "$max_age" ]; then
      cleanup_bot_worktree "$repo_root" "$wt_dir"
      stale_count=$((stale_count + 1))
    fi
  done

  # Also run git worktree prune to clean up tracking
  git -C "$repo_root" worktree prune 2>/dev/null || true

  echo "$stale_count"
}

# Fast-prune worktrees named `pr-<id>-<pid>` whose owning router PID is no longer
# alive — regardless of age. Complements prune_stale_worktrees() (purely age-based)
# for pr-bot, which keys each worktree on the owning router's PID. On a memory-
# pressured host the OS can SIGKILL a router before its cleanup() runs
# `git worktree remove`, leaving a uniquely-named orphan every time; waiting out the
# 24h age gate lets them accrete. A dead-PID suffix is an unambiguous orphan signal.
#
# SAFETY: matches ONLY the strict `pr-<digits>-<digits>` shape (two trailing numeric
# segments: PR id then PID). This deliberately excludes:
#   - bare legacy `pr-<id>` (one numeric segment) — its trailing number is a PR id,
#     not a PID; `kill -0 <prid>` is meaningless, so it is left to the age pruner.
#   - other-bot names like `issue-cve-2024` (last-but-one segment not all digits).
# Only a dir whose router PID is verifiably DEAD is removed.
# Usage: prune_dead_pid_worktrees <repo_root> <worktree_base_dir>
prune_dead_pid_worktrees() {
  local repo_root="$1"
  local worktree_base="$2"

  [ ! -d "$worktree_base" ] && return 0

  local pruned=0
  for wt_dir in "$worktree_base"/*/; do
    [ ! -d "$wt_dir" ] && continue
    local base pid
    base=$(basename "$wt_dir")
    # Require the strict pr-<id>-<pid> shape; anything else is not ours to fast-prune.
    [[ "$base" =~ ^pr-[0-9]+-[0-9]+$ ]] || continue
    pid="${base##*-}"
    # Live PID → cross-check that it's actually a router, not a recycled PID.
    # On a host with frequent jetsam kills and fast PID cycling, an unrelated
    # process can inherit the dead router's PID, causing kill -0 to succeed and
    # the orphan worktree to persist until the 24h age pruner runs. Cross-check
    # the process comm: a live pr-bot router is always a bash process. If the PID
    # is alive but not bash, it was recycled — safe to prune.
    if kill -0 "$pid" 2>/dev/null; then
      local pid_comm
      pid_comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk -F/ '{print $NF}') || pid_comm=""
      case "$pid_comm" in
        bash*|sh*|zsh*) continue ;;  # Plausible router — leave it alone
        "") continue ;;              # Can't read comm — safe direction: skip
        *)                           # PID recycled into a non-shell process
          ;;
      esac
    fi
    cleanup_bot_worktree "$repo_root" "$wt_dir"
    pruned=$((pruned + 1))
  done

  git -C "$repo_root" worktree prune 2>/dev/null || true
  echo "$pruned"
}
