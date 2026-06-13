#!/usr/bin/env bash
set -euo pipefail

# WU10: Bash version check — wait -n requires bash 4.3+, process substitution needs bash 4+
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "❌ bash 4+ required (found ${BASH_VERSION}). On macOS: brew install bash"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Start the PR Bot worker — subscribes to ntfy and drives Claude Code
to address PR review comments automatically.

Options:
  -h, --help          Show this help message
  -c, --config FILE   Path to config.env (default: ./config.env)
  -t, --topic TOPIC   ntfy topic name (default: pr-bot)
  -n, --dry-run       Print received messages without invoking Claude Code
  -v, --verbose       Enable verbose logging
  -d, --daemon        Run as a background daemon (survives SSH disconnect)
  --service           Foreground mode for systemd/launchd (no daemonization, stdout logging)
  --stop              Stop a running daemon
  --status            Check if daemon is running
  --test              Publish a test message and exit
  --reap-orphans-dryrun  Inspect the live daemon's cgroup and list leaked
                      off-tree subprocesses that WOULD be reaped (no kills); exit 0

Prerequisites:
  curl, jq, git, claude (Claude Code CLI)

Quick start:
  1. cp config.env.example config.env
  2. Edit config.env with your ADO PAT and ntfy URL
  3. ./start.sh              # foreground
  4. ./start.sh --daemon     # background (survives SSH disconnect)
  5. ./start.sh --status     # check if running
  6. ./start.sh --stop       # stop daemon

Environment variables (override config.env):
  NTFY_URL        ntfy server URL (e.g. https://ntfy.example.com/ntfy)
  ADO_ORG         Azure DevOps organization name
  ADO_PROJECT     Azure DevOps project name
  ADO_PAT         Azure DevOps personal access token
  MAX_CONCURRENT  Max parallel PR jobs (default: 3)
EOF
  exit 0
}

# Parse args
CONFIG_FILE="$SCRIPT_DIR/config.env"
TOPIC="pr-bot"
DRY_RUN=false
VERBOSE=false
TEST_MODE=false
DAEMON_MODE=false
STOP_MODE=false
STATUS_MODE=false
SERVICE_MODE=false
# Concurrency + memory admission. Defaults tuned from live measurement (2026-06):
# a mature `claude --print` PR session resides at ~0.8–1.2 GB RSS (not the
# ~0.4–0.6 GB the original weights assumed). systemd enforces MemoryMax=3G with
# KillMode=control-group, so ONE Claude breaching the cap OOM-kills the WHOLE bot.
# Budget sits ~370 MB under the 3 GB wall so check_resource_budget + the
# aggregate-RSS watchdog defer/trim BEFORE the cgroup kills us. 2 concurrent
# MEDIUM(1100)+overhead(300)=2500 MB fits; a 3rd would breach 3 GB → MAX_CONCURRENT=2.
MAX_CONCURRENT="${MAX_CONCURRENT:-2}"
MEMORY_BUDGET_MB="${MEMORY_BUDGET_MB:-2700}"  # Admission budget; ~370MB under the 3G systemd cap
RESERVED_OVERHEAD_MB="${RESERVED_OVERHEAD_MB:-300}"  # OS/shell/git/ntfy/heartbeat overhead (measured ~250MB)
# Per-session watchdog (Pass-1) kill FLOOR. A mature `claude --print` session sits
# at ~0.8–1.2 GB RSS REGARDLESS of PR size — that's the fixed node+MCP+model-context
# runtime baseline, not PR-proportional work. The 150%-of-estimate limit for a SMALL
# PR (700→1050) lands BELOW that baseline, so the watchdog false-kills healthy work
# the moment it matures (observed: PR #1343 killed at 1087 MB, published nothing,
# logged "completed successfully"). The floor lifts the effective limit to
# max(estimate×1.5, FLOOR) so only a genuine runaway/leak (≈2 GB — e.g. #1360 at
# 1961 MB) is shed. Pass-2's authoritative cgroup guard remains the true OOM backstop.
MIN_SESSION_KILL_MB="${MIN_SESSION_KILL_MB:-1500}"
# Orphan-subprocess reaper (4th OOM-defense layer). Claude workers shell out to
# `az`/azure.cli (python); when a router's session ends abnormally (timeout /
# OOM-shed / kill) some grandchildren reparent to the systemd --user manager but
# STAY in the pr-bot cgroup, so they keep counting against memory.current while
# being descendants of NO tracked ACTIVE_PID (invisible to both watchdog passes).
# The reaper diffs the cgroup's process list against the daemon's own subtree and
# terminates the leaked off-tree procs. Age gate + comm denylist spare the one
# real false-positive class: detached git/credential housekeeping that briefly
# leaves the tree but is legitimate.
ORPHAN_REAP_ENABLED="${ORPHAN_REAP_ENABLED:-true}"
ORPHAN_REAP_AGE_SECS="${ORPHAN_REAP_AGE_SECS:-180}"      # only reap procs older than this
ORPHAN_REAP_GRACE_SECS="${ORPHAN_REAP_GRACE_SECS:-5}"    # TERM→KILL grace per subtree
ORPHAN_REAP_COMM_DENYLIST="${ORPHAN_REAP_COMM_DENYLIST:-git git-gc git-maintenance git-repack git-pack-objects fsmonitor--daemon git-credential gpg gpg-agent ssh ssh-agent}"
DEFER_QUEUE_DIR=""  # Set after STATE_DIR is known
QUEUE_DIR=""  # Persistent message queue, set after STATE_DIR is known
REAP_DRYRUN=false   # set by --reap-orphans-dryrun

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage ;;
    -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
    -t|--topic)   TOPIC="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -d|--daemon)  DAEMON_MODE=true; shift ;;
    --stop)       STOP_MODE=true; shift ;;
    --status)     STATUS_MODE=true; shift ;;
    --service)    SERVICE_MODE=true; shift ;;
    --test)       TEST_MODE=true; shift ;;
    --reap-orphans-dryrun) REAP_DRYRUN=true; shift ;;
    *)            echo "Unknown option: $1"; usage ;;
  esac
done

# --- Daemon management (PID file + log file) ---
STATE_DIR="$SCRIPT_DIR/.pr-bot-state"
mkdir -p "$STATE_DIR"
DEFER_QUEUE_DIR="$STATE_DIR/deferred"
mkdir -p "$DEFER_QUEUE_DIR"
QUEUE_DIR="$STATE_DIR/queue"
mkdir -p "$QUEUE_DIR"

# ---------------------------------------------------------------------------
# Orphan-subprocess reaper helpers (4th OOM-defense layer) — HOISTED here, above
# the snapshot block, so `--reap-orphans-dryrun` can short-circuit and reuse them
# before the daemon-only snapshot/PID setup runs. The live reaper
# (reap_orphaned_subprocesses, defined later) calls the same predicate so "what
# we'd reap" can never diverge from "what we reap".
# ---------------------------------------------------------------------------

# Portable RSS measurement (macOS + Linux), in MB.
get_pid_rss_mb() {
  local pid="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%d", $1/1024}'
  else
    awk '/^VmRSS:/{printf "%d", $2/1024}' "/proc/$pid/status" 2>/dev/null
  fi
}

# Collect a PID and ALL its descendants (recursive, depth-unbounded), one per line.
# CRITICAL: the dispatch tree is
#   ( pr_router.sh ) &  →  subshell-bash → pr_router-bash → timeout → claude → {node, MCP}
# so the memory-heavy procs sit at DEPTH 2–4. A depth-1 `pgrep -P` walk stops at
# the ~16MB `timeout` wrapper and misses the ~600MB claude subtree (~39× under-count
# measured live). Every memory/ownership decision MUST walk the full tree — this is
# also what defines the daemon's "protected" set for the orphan reaper.
_collect_subtree_pids() {
  local root="$1"
  echo "$root"
  local kids
  kids=$(pgrep -P "$root" 2>/dev/null) || return 0
  local k
  for k in $kids; do
    _collect_subtree_pids "$k"
  done
}

# Resolve the cgroup.procs PATH for a given PID. Mirrors get_cgroup_mem_mb
# (resolve the cgroup-v2 rel path → build the /sys/fs/cgroup path → guard
# readable) but (a) reads /proc/<pid>/cgroup — NOT /proc/self — so the dry-run
# can resolve a DIFFERENT (the live daemon's) PID's cgroup, and (b) targets the
# sibling cgroup.procs (the cgroup's full PID set). Returns 1 (empty) on
# non-Linux / cgroup-v1 so callers no-op safely.
get_cgroup_procs_for_pid() {
  local pid="$1" rel procs
  rel=$(awk -F: '$1=="0"{print $3}' "/proc/$pid/cgroup" 2>/dev/null)
  [ -z "$rel" ] && return 1
  procs="/sys/fs/cgroup${rel}/cgroup.procs"
  [ -r "$procs" ] || return 1
  echo "$procs"
}

# Single-sourced orphan predicate (read-only; NEVER kills). Given a daemon root
# PID and a cgroup.procs file path, print one line "pid comm age_s rss_mb" for
# every LEAKED off-tree process, i.e. a PID that is:
#   (1) in cgroup.procs (read FIRST, before the subtree, so a proc that appears
#       mid-scan can't be mistaken for an orphan — TOCTOU-safe with the age gate);
#   (2) NOT in subtree(root) and != root and != PID 1;
#   (3) older than ORPHAN_REAP_AGE_SECS; and
#   (4) whose comm is not under the ORPHAN_REAP_COMM_DENYLIST families.
# Used by BOTH the dry-run flag and the live reaper, so the kill predicate is
# defined exactly once.
_select_orphan_candidates() {
  local root="$1" procs_path="$2"
  [ -n "$root" ] || return 0
  [ -n "$procs_path" ] || return 0
  local procs
  procs=$(cat "$procs_path" 2>/dev/null) || return 0   # cgroup.procs, read FIRST
  [ -n "$procs" ] || return 0
  # Protected set = the daemon's own full subtree (routers, heartbeat, ntfy curl,
  # watchdog pinger, recover_crashed_prs, …). Everything else in-cgroup is suspect.
  # Built as an associative array for O(1) membership tests (no fork per PID).
  local subtree
  subtree=$(_collect_subtree_pids "$root" 2>/dev/null | sort -u) || subtree=""
  local -A subtree_set=()
  local _st_pid
  while read -r _st_pid; do
    [[ "$_st_pid" =~ ^[0-9]+$ ]] && subtree_set[$_st_pid]=1
  done <<< "$subtree"
  local pid comm age rss deny skip
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [ "$pid" = "$root" ] && continue
    [ "$pid" = "1" ] && continue
    # In the daemon's subtree → legitimate, skip.
    if [[ -v "subtree_set[$pid]" ]]; then
      continue
    fi
    # Age gate (etimes = elapsed seconds). Missing/young → skip (covers TOCTOU:
    # a freshly-forked legit grandchild not yet visible in the subtree snapshot).
    age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || age=""
    [[ "$age" =~ ^[0-9]+$ ]] || continue
    [ "$age" -ge "${ORPHAN_REAP_AGE_SECS:-180}" ] || continue
    # Comm denylist — spare detached git/credential housekeeping that can briefly
    # leave the tree but is legitimate. PREFIX match (case glob) so it is robust
    # to the 15-char /proc comm truncation (git-pack-objects, fsmonitor--daemon)
    # and strictly conservative: it can only ever spare MORE, never reap more.
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk -F/ '{print $NF}') || comm=""
    [ -n "$comm" ] || continue
    skip=0
    # Disable pathname expansion so glob chars in a custom denylist are safe.
    local _restore_glob; _restore_glob=$(shopt -p nullglob failglob 2>/dev/null || true); set -f
    for deny in ${ORPHAN_REAP_COMM_DENYLIST:-}; do
      case "$comm" in
        "$deny"*) skip=1; break ;;
      esac
    done
    eval "$_restore_glob" 2>/dev/null; set +f
    [ "$skip" -eq 1 ] && continue
    rss=$(get_pid_rss_mb "$pid" 2>/dev/null) || rss=0
    echo "$pid $comm $age ${rss:-0}"
  done <<< "$procs"
}

# --- `--reap-orphans-dryrun`: inspect the LIVE daemon's cgroup, list leaked
# off-tree subprocesses that WOULD be reaped, then exit. MUST short-circuit here,
# BEFORE the snapshot `rm -rf "$SNAPSHOT_DIR"` below, so a standalone invocation
# never clobbers the running daemon's script snapshot. Read-only; exits 0 always.
if [ "$REAP_DRYRUN" = true ]; then
  _dry_pidfile="$STATE_DIR/daemon.pid"
  if [ ! -f "$_dry_pidfile" ]; then
    echo "notice: no daemon PID file ($_dry_pidfile) — pr-bot not running; nothing to inspect."
    exit 0
  fi
  _dry_daemon=$(cat "$_dry_pidfile" 2>/dev/null || true)
  if ! [[ "$_dry_daemon" =~ ^[0-9]+$ ]] || ! kill -0 "$_dry_daemon" 2>/dev/null; then
    echo "notice: daemon PID '${_dry_daemon:-?}' is not alive — nothing to inspect."
    exit 0
  fi
  _dry_procs=$(get_cgroup_procs_for_pid "$_dry_daemon" 2>/dev/null || true)
  if [ -z "$_dry_procs" ]; then
    echo "notice: could not read cgroup.procs for daemon $_dry_daemon (non-Linux / cgroup-v1?) — no-op."
    exit 0
  fi
  echo "Dry-run: inspecting pr-bot cgroup of daemon PID $_dry_daemon"
  echo "  cgroup.procs: $_dry_procs"
  echo "  age gate: ≥${ORPHAN_REAP_AGE_SECS}s   denylist: ${ORPHAN_REAP_COMM_DENYLIST}"
  echo "  PID      COMM              AGE_S    RSS_MB"
  _dry_total=0
  _dry_count=0
  while read -r _p _c _a _r; do
    [ -n "$_p" ] || continue
    printf '  %-8s %-16s %-8s %s\n' "$_p" "$_c" "$_a" "$_r"
    _dry_total=$((_dry_total + ${_r:-0}))
    _dry_count=$((_dry_count + 1))
  done < <(_select_orphan_candidates "$_dry_daemon" "$_dry_procs")
  echo "  ----"
  echo "Would reap $_dry_count orphaned subprocess(es), ~${_dry_total} MB reclaimable."
  exit 0
fi

# --- Snapshot scripts for branch-switch resilience ---
# Copy all bot scripts to a stable location so git checkout / branch switching
# can't disrupt the running process mid-execution (exit status 5/NOTINSTALLED).
# Also snapshot the shared/ sibling directory (ado_api.sh, logging.sh, worktree.sh)
# since scripts reference it via ../shared/ relative paths.
SNAPSHOT_DIR="$STATE_DIR/script-snapshot"
rm -rf "$SNAPSHOT_DIR"
mkdir -p "$SNAPSHOT_DIR"
cp "$SCRIPT_DIR"/*.sh "$SNAPSHOT_DIR/"
# Snapshot shared scripts (sibling dir referenced by ../shared/ from SCRIPT_DIR)
if [ -d "$SCRIPT_DIR/../shared" ]; then
  mkdir -p "$SNAPSHOT_DIR/../shared"
  cp "$SCRIPT_DIR/../shared"/*.sh "$SNAPSHOT_DIR/../shared/"
  chmod +x "$SNAPSHOT_DIR/../shared"/*.sh
fi
chmod +x "$SNAPSHOT_DIR"/*.sh
# Redirect SCRIPT_DIR for all dispatched routers to use the snapshot
RUNTIME_SCRIPT_DIR="$SNAPSHOT_DIR"

PID_FILE="$STATE_DIR/daemon.pid"
LOG_FILE="$STATE_DIR/daemon.log"

daemon_is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

if [ "$STATUS_MODE" = true ]; then
  if daemon_is_running; then
    PID=$(cat "$PID_FILE")
    echo "✅ PR Bot daemon is running (PID: $PID)"
    echo "   Log: $LOG_FILE"
    echo "   Follow logs: tail -f $LOG_FILE"
  else
    echo "⭕ PR Bot daemon is not running"
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
  fi
  exit 0
fi

if [ "$STOP_MODE" = true ]; then
  if daemon_is_running; then
    PID=$(cat "$PID_FILE")
    echo "🛑 Stopping PR Bot daemon (PID: $PID)..."
    kill "$PID" 2>/dev/null || true
    # Wait up to 10s for graceful shutdown
    for i in $(seq 1 10); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo "   Force killing..."
      kill -9 "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo "✅ PR Bot daemon stopped"
  else
    echo "⭕ PR Bot daemon is not running"
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
  fi
  exit 0
fi

# --- Config loading and validation ---

# Load config file if it exists — validate it only contains variable assignments
if [ -f "$CONFIG_FILE" ]; then
  if grep -qvE '^[[:space:]]*#|^[[:space:]]*$|^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_FILE"; then
    echo "❌ Config file contains non-assignment lines: $CONFIG_FILE"
    echo "   Only VAR=value lines, comments (#), and blank lines are allowed."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  [[ "$VERBOSE" == "true" ]] && echo "Loaded config from $CONFIG_FILE"
else
  echo "⚠️  Config file not found: $CONFIG_FILE (using environment variables)"
fi

# Load secrets file if it exists (gitignored, separate from config)
SECRETS_FILE="$(dirname "$CONFIG_FILE")/.secrets.env"
if [ -f "$SECRETS_FILE" ]; then
  if grep -qvE '^[[:space:]]*#|^[[:space:]]*$|^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_FILE"; then
    echo "❌ Secrets file contains non-assignment lines: $SECRETS_FILE"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$SECRETS_FILE"
  [[ "$VERBOSE" == "true" ]] && echo "Loaded secrets from $SECRETS_FILE"
fi

# Validate prerequisites
for cmd in curl jq claude git; do
  command -v "$cmd" >/dev/null || { echo "❌ Missing required command: $cmd"; exit 1; }
done

# Validate required config
: "${NTFY_URL:?NTFY_URL is required — set in config.env or environment}"
: "${ADO_ORG:?ADO_ORG is required — set in config.env or environment}"
: "${ADO_PROJECT:?ADO_PROJECT is required — set in config.env or environment}"

# Validate auth method-specific requirements
case "${ADO_AUTH_METHOD:-pat}" in
  pat)
    : "${ADO_PAT:?ADO_PAT is required when ADO_AUTH_METHOD=pat — set in .secrets.env or environment}"
    ;;
  entra-sp)
    : "${AZURE_TENANT_ID:?AZURE_TENANT_ID required for ADO_AUTH_METHOD=entra-sp}"
    : "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID required for ADO_AUTH_METHOD=entra-sp}"
    : "${AZURE_CLIENT_SECRET:?AZURE_CLIENT_SECRET required for ADO_AUTH_METHOD=entra-sp}"
    ;;
  entra-wi)
    : "${AZURE_TENANT_ID:?AZURE_TENANT_ID required for ADO_AUTH_METHOD=entra-wi}"
    : "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID required for ADO_AUTH_METHOD=entra-wi}"
    : "${AZURE_FEDERATED_TOKEN_FILE:?AZURE_FEDERATED_TOKEN_FILE required for ADO_AUTH_METHOD=entra-wi}"
    ;;
  *)
    echo "❌ Unknown ADO_AUTH_METHOD: ${ADO_AUTH_METHOD}" ; exit 1
    ;;
esac

# Export for child scripts
export NTFY_URL ADO_ORG ADO_PROJECT ADO_PAT ADO_AUTH_METHOD VERBOSE STATE_DIR
# Only export Entra ID vars relevant to the configured auth method
case "${ADO_AUTH_METHOD:-pat}" in
  entra-sp)
    export AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET
    ;;
  entra-wi)
    export AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_FEDERATED_TOKEN_FILE
    ;;
esac

# Export Claude Code env vars so child processes inherit them
export ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
export CLAUDE_CODE_MAX_OUTPUT_TOKENS DISABLE_TELEMETRY CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
export DISABLE_ERROR_REPORTING DISABLE_BUG_COMMAND DISABLE_NON_ESSENTIAL_MODEL_CALLS

# .NET memory containment for bot-spawned `dotnet test`/`dotnet build`.
# a high-core host (e.g. 128 logical cores) has many cores. The .NET default **Server GC** pre-reserves a heap
# segment PER LOGICAL CORE, so even a trivial `dotnet test --filter TestCategory=L0`
# on a tiny diff balloons to ~1 GB of committed heap REGARDLESS of how small the work
# is. Stacked on the ~1 GB mature `claude --print` baseline, that pushed the worker
# subtree to ~2 GB — over the MIN_SESSION_KILL_MB=1500 per-session kill-floor — so
# Pass-1 of kill_oversized_claudes SIGKILLed the worker mid-build, BEFORE it could
# commit/push its fix or resolve threads, and the heartbeat re-dispatched it into an
# infinite re-balloon/kill loop with the circuit breaker blind (observed: PR #1385,
# a 2-file `.cs` PR, killed at 2049 MB on every cycle, published nothing).
#   Forcing **Workstation GC** (a single on-demand heap, NOT one segment per core)
# collapses that reservation to a few hundred MB so test/build verification fits under
# the floor. We deliberately do NOT set DOTNET_GCHeapHardLimit: a hard cap makes the
# runtime THROW OutOfMemoryException rather than use more RAM, which on the 1233-test
# L0 suite would just trade the kill-loop for a test-failure loop. The existing
# per-session floor (1500 MB) + the 3 GB cgroup remain the authoritative memory
# backstops — they only tripped because of the per-core reservation Workstation GC now
# removes. Exported so every router→timeout→claude→dotnet descendant inherits it; all
# values are config.env-overridable (config.env is sourced above at line ~180, so a
# value set there wins the `:-`).
export DOTNET_gcServer="${DOTNET_gcServer:-0}"                  # Workstation GC: one heap, not one-per-core
export DOTNET_CLI_TELEMETRY_OPTOUT="${DOTNET_CLI_TELEMETRY_OPTOUT:-1}"
export DOTNET_NOLOGO="${DOTNET_NOLOGO:-1}"

# Source auth helper for health checks and crash recovery
if [ -f "$SCRIPT_DIR/../shared/ado_auth.sh" ]; then
  source "$SCRIPT_DIR/../shared/ado_auth.sh"
fi

# Source worktree helpers — periodic_health_check uses prune_stale_worktrees() to
# GC worktrees orphaned when a router dies WITHOUT running cleanup() (a cgroup OOM
# or SIGKILL skips the EXIT trap, so its worktree leaks forever). Without this the
# bot accreted 1.5 GB of stale worktrees for long-merged PRs. Sourced via the same
# ../shared/ path the snapshot copies (see the snapshot block above).
if [ -f "$SCRIPT_DIR/../shared/worktree.sh" ]; then
  source "$SCRIPT_DIR/../shared/worktree.sh"
else
  echo "[$(date '+%H:%M:%S')] ℹ️  shared/worktree.sh not found — worktree GC disabled"
fi

# Resolve the TARGET repository root — the repo the bot SERVICES (creates worktrees
# in, fetches, pushes). This is distinct from the harness's own repo ($SCRIPT_DIR's
# toplevel, used only for git-gc taming of the harness checkout). The per-PR worktree
# FILES live under STATE_DIR, but `git worktree add` registers them against this
# target repo's .git — so worktree GC (prune_stale_worktrees) must use THIS root.
# Precedence mirrors pr_router.sh: TARGET_REPO_DIR, else CWD git toplevel (legacy).
if [ -n "${TARGET_REPO_DIR:-}" ]; then
  TARGET_REPO_ROOT=$(git -C "$TARGET_REPO_DIR" rev-parse --show-toplevel 2>/dev/null) || TARGET_REPO_ROOT=""
else
  TARGET_REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || TARGET_REPO_ROOT=""
fi
export TARGET_REPO_ROOT

if [ "$TEST_MODE" = true ]; then
  echo "📤 Publishing test message to ${NTFY_URL}/${TOPIC}..."
  curl -s -d '{"test":"hello from pr-bot"}' "${NTFY_URL}/${TOPIC}"
  echo ""
  echo "✅ Test message sent"
  exit 0
fi

# --- Daemon mode: re-exec ourselves in the background ---
if [ "$DAEMON_MODE" = true ]; then
  if daemon_is_running; then
    PID=$(cat "$PID_FILE")
    echo "⚠️  PR Bot daemon is already running (PID: $PID)"
    echo "   Stop it first: $0 --stop"
    exit 1
  fi

  echo "🚀 Starting PR Bot daemon..."

  # Build the args to re-exec without --daemon to avoid infinite loop
  ARGS=(-c "$CONFIG_FILE" -t "$TOPIC")
  [ "$DRY_RUN" = true ] && ARGS+=(-n)
  [ "$VERBOSE" = true ] && ARGS+=(-v)

  # nohup + disown ensures the process survives SSH disconnect.
  # Redirect stdout/stderr to log file with rotation.
  nohup "$0" "${ARGS[@]}" >> "$LOG_FILE" 2>&1 &
  DAEMON_PID=$!
  disown "$DAEMON_PID"
  echo "$DAEMON_PID" > "$PID_FILE"

  echo "✅ PR Bot daemon started (PID: $DAEMON_PID)"
  echo "   Log: $LOG_FILE"
  echo "   Follow logs: tail -f $LOG_FILE"
  echo "   Stop: $0 --stop"
  exit 0
fi

# --- Foreground mode ---

echo "🤖 PR Bot listening on ${NTFY_URL}/${TOPIC}..."
echo "   Config: $CONFIG_FILE | Dry-run: $DRY_RUN | Verbose: $VERBOSE"
echo "   State dir: $STATE_DIR | Max concurrent: $MAX_CONCURRENT"
echo "   Script snapshot: $RUNTIME_SCRIPT_DIR (branch-switch safe)"
echo "   Press Ctrl+C to stop"
echo ""

# Tame git auto-gc on the bot's repo (macOS Launch-Constraint SIGKILL guard).
# Every router runs `git -C "$REPO_ROOT" fetch origin main` per cycle; with gc.auto
# unset, git forks a background `git-gc` once loose objects exceed the threshold.
# On macOS 26.x that relocated `git-gc` child is SIGKILL'd with CODESIGNING /
# "Launch Constraint Violation" (observed 2026-06-13), so it never packs — loose
# objects accrete and gc is re-attempted ever more often.
#
# Defense layers:
#   1. Per-command `-c gc.auto=0` on every fetch in pr_router.sh / worktree.sh — the
#      load-bearing mechanism. No persistent `git config gc.auto 0` is written, so
#      the repo's config stays clean for interactive use after the bot stops.
#   2. `maintenance.auto false` is set persistently to prevent git-maintenance from
#      spawning background gc; failure is logged (not swallowed).
#   3. One-shot `git gc --quiet` at startup packs loose objects on our own terms.
#      Its PID is captured and waited on before the dispatch loop.
# Env-overridable: GIT_AUTOGC_TAME=false to skip; GIT_AUTOGC_PACK=false to skip the pack.
if [ "${GIT_AUTOGC_TAME:-true}" = "true" ]; then
  _bot_repo_root=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || _bot_repo_root=""
  if [ -n "$_bot_repo_root" ]; then
    # Per-command `-c gc.auto=0` in pr_router.sh/worktree.sh already guards every
    # bot-initiated fetch; persistent `git config gc.auto 0` is redundant and leaves
    # auto-gc silently disabled for interactive use after the bot stops.
    echo "[$(date '+%H:%M:%S')] 🧰 git auto-gc taming active (per-command -c gc.auto=0 on all bot fetches)"
    git -C "$_bot_repo_root" config maintenance.auto false 2>/dev/null \
      || echo "[$(date '+%H:%M:%S')] ⚠️  Failed to disable maintenance.auto — git-maintenance may fork background gc"
    if [ "${GIT_AUTOGC_PACK:-true}" = "true" ]; then
      ( git -C "$_bot_repo_root" -c gc.auto=0 gc --quiet 2>/dev/null \
        && echo "[$(date '+%H:%M:%S')] 🧰 Packed loose git objects (controlled, one-shot)" ) &
      _GC_BG_PID=$!
    fi
  fi
  unset _bot_repo_root
fi

# Wait for the one-shot git gc (if spawned) before entering the dispatch loop,
# so its log line prints in order and it can't become an orphan if the daemon
# receives SIGTERM during startup.
if [ -n "${_GC_BG_PID:-}" ]; then
  wait "$_GC_BG_PID" 2>/dev/null || true
  unset _GC_BG_PID
fi

# Track background jobs for concurrency limiting
ACTIVE_PIDS=()

cleanup() {
  echo ""
  echo "👋 PR Bot stopping — waiting for active jobs..."
  for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "👋 PR Bot stopped"
  exit 0
}
trap cleanup INT TERM

# WU10: systemd watchdog support in --service mode (must be after cleanup definition)
if [ "$SERVICE_MODE" = true ] && [ -n "${NOTIFY_SOCKET:-}" ]; then
  systemd-notify --ready 2>/dev/null || true
  # Start watchdog pinger in background
  WATCHDOG_USEC="${WATCHDOG_USEC:-0}"
  if [ "$WATCHDOG_USEC" -gt 0 ] 2>/dev/null; then
    WATCHDOG_SEC=$(( WATCHDOG_USEC / 1000000 / 2 ))  # ping at half the interval
    [ "$WATCHDOG_SEC" -lt 1 ] && WATCHDOG_SEC=1
    (while true; do systemd-notify WATCHDOG=1 2>/dev/null; sleep "$WATCHDOG_SEC"; done) &
    WATCHDOG_PING_PID=$!
    # Override trap to also clean up watchdog — cleanup is already defined above
    trap 'kill "$WATCHDOG_PING_PID" 2>/dev/null || true; cleanup' INT TERM
  fi
fi

# Write our PID so --stop/--status work in foreground mode too
echo $$ > "$PID_FILE"

# PR weight estimation — deterministic token proxy based on file/comment count
estimate_pr_weight() {
  local file_count="${1:-0}" comment_count="${2:-0}"
  if [ "$file_count" -ge 20 ] || [ "$comment_count" -ge 20 ]; then
    echo "LARGE"
  elif [ "$file_count" -ge 10 ] || [ "$comment_count" -ge 10 ]; then
    echo "MEDIUM"
  else
    echo "SMALL"
  fi
}

weight_to_mb() {
  # Real mature `claude --print` RSS measured live (2026-06): ~0.8–1.2 GB for a
  # working PR session, climbing with file/comment count. The old 400/600/900
  # values were ~40% of reality, which let 3 "MEDIUM" PRs be admitted at a
  # 1800 MB budget while actually consuming ~3 GB → cgroup OOM. These are the
  # per-session estimates the admission check and the RSS watchdog budget against.
  case "${1:-MEDIUM}" in
    SMALL)  echo 700 ;;
    MEDIUM) echo 1100 ;;
    LARGE)  echo 1600 ;;
    *)      echo 1100 ;;
  esac
}

# Reap finished background jobs and update the active list
reap_jobs() {
  local still_active=()
  for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then
      still_active+=("$pid")
    else
      # Job finished. The dispatch wrapper is `( router || true ) &`, so wait
      # always returns 0 — the router's TRUE exit code is written to
      # pr-<id>.lastexit by its cleanup() (Change 3). Read it for honest logging
      # so a crash-looping PR is no longer masked as "✅ completed successfully".
      wait "$pid" 2>/dev/null && true
      local rc=$?
      local pr_id="${PR_DISPATCH_ID[$pid]:-}"
      local true_rc="$rc"
      local hard_killed=false
      if [ -n "$pr_id" ]; then
        local lastexit_file="$STATE_DIR/pr-${pr_id}.lastexit"
        if [ -f "$lastexit_file" ]; then
          local file_rc
          file_rc=$(head -1 "$lastexit_file" 2>/dev/null)
          [[ "$file_rc" =~ ^[0-9]+$ ]] && true_rc="$file_rc"
          rm -f "$lastexit_file" 2>/dev/null || true
        fi
        # In-flight breadcrumb still present → the router armed its cleanup() EXIT
        # trap but never ran it, i.e. it was hard-killed by an UNCATCHABLE signal
        # (macOS jetsam SIGKILL under memory pressure, an OOM, or our own
        # _kill_subtree). The ( router || true ) dispatch wrapper masks an inner
        # SIGKILL as wait-rc 0, which previously fell to the success branch below:
        # it logged a FALSE "✅ completed successfully" AND deleted the queue file,
        # silently DROPPING the PR (the observed `Killed: 9` at the dispatch line did
        # exactly this). The breadcrumb is created only AFTER every pre-trap early
        # bail ([no-bot]/*-wip/duplicate/inactive), so those clean skips are never
        # misread. Force a crash classification so the queue file is PRESERVED for
        # replay; the heartbeat also re-dispatches (~5min) without a restart.
        if [ -f "$STATE_DIR/pr-${pr_id}.inflight" ]; then
          hard_killed=true
          rm -f "$STATE_DIR/pr-${pr_id}.inflight" 2>/dev/null || true
          [ "$true_rc" -eq 0 ] && true_rc=137  # SIGKILL — cleanup() demonstrably did not run
        fi
      fi
      if [ "$true_rc" -eq 75 ]; then
        # EX_TEMPFAIL — the router YIELDED (lost a push race to a concurrent human/
        # agent driver after bounded rebase+retry). It already released its lease as
        # non-active, so pr_heartbeat.sh re-dispatches it (~5min) once the contention
        # clears. This is a cooperative hand-off, NOT a crash: do not alarm, do not
        # treat as success, and do not re-queue here (the heartbeat owns retry).
        echo "[$(date '+%H:%M:%S')] 🤝 Router process $pid (PR #${pr_id:-unknown}) yielded (branch contended) — heartbeat will re-dispatch"
        # Drop the persistent queue file so we don't tight-loop re-replaying it; the
        # heartbeat re-queues from the live PR list when the branch settles.
        [ -n "${PR_QUEUE_FILE[$pid]:-}" ] && rm -f "${PR_QUEUE_FILE[$pid]}"
      elif [ "$hard_killed" = true ]; then
        # Hard-killed: keep the queued payload so startup replay / heartbeat recovers it.
        echo "[$(date '+%H:%M:%S')] 💥 Router process $pid (PR #${pr_id:-unknown}) hard-killed (no cleanup; likely jetsam/OOM SIGKILL) — preserving queued payload for replay"
      elif [ "$true_rc" -ne 0 ]; then
        echo "[$(date '+%H:%M:%S')] ⚠️  Router process $pid (PR #${pr_id:-unknown}) exited with code $true_rc"
      else
        echo "[$(date '+%H:%M:%S')] ✅ Router process $pid (PR #${pr_id:-unknown}) completed successfully"
        # Clean up persistent queue file on success
        [ -n "${PR_QUEUE_FILE[$pid]:-}" ] && rm -f "${PR_QUEUE_FILE[$pid]}"
      fi
      unset "PR_BUDGET[$pid]" 2>/dev/null || true
      unset "PR_QUEUE_FILE[$pid]" 2>/dev/null || true
      unset "PR_DISPATCH_ID[$pid]" 2>/dev/null || true
    fi
  done
  ACTIVE_PIDS=("${still_active[@]+"${still_active[@]}"}")
}

# --- Resource-aware backpressure ---
# NOTE: get_pid_rss_mb() and _collect_subtree_pids() are defined earlier (hoisted
# above the snapshot block so `--reap-orphans-dryrun` can reuse them). They are
# the portable RSS reader and the recursive full-subtree walker, respectively.

# Sum RSS (MB) of a PID and its entire descendant subtree.
_subtree_rss_mb() {
  local root="$1" total=0 p rss
  for p in $(_collect_subtree_pids "$root" | sort -u); do
    rss=$(get_pid_rss_mb "$p") || continue
    total=$((total + ${rss:-0}))
  done
  echo "$total"
}

# Authoritative cgroup memory (MB) — the EXACT number systemd compares to
# MemoryMax for the OOM kill (cgroup v2: memory.current). This sidesteps any
# RSS-summing inaccuracy (shared pages, missed procs) and is the truest aggregate
# signal available. Returns empty on non-Linux / cgroup-v1 so callers fall back.
get_cgroup_mem_mb() {
  local rel cur
  rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup 2>/dev/null)
  [ -z "$rel" ] && return 1
  cur="/sys/fs/cgroup${rel}/memory.current"
  [ -r "$cur" ] || return 1
  awk '{printf "%d", $1/1024/1024}' "$cur" 2>/dev/null
}

# Terminate a handler and its ENTIRE descendant subtree. A plain `kill $pid` on
# the tracked subshell-bash does NOT propagate to the timeout→claude→node/MCP
# children — they are reparented to init and KEEP consuming cgroup memory, so a
# memory-shed that killed only the shell would free nothing (verified live).
# We snapshot the full PID set FIRST (before anything exits and detaches), TERM
# the leaves-up, then KILL -9 any survivors after a grace period.
_kill_subtree() {
  local root="$1" grace="${2:-5}"
  local pids
  pids=$(_collect_subtree_pids "$root" | sort -rn -u)  # children before parents
  local p
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  sleep "$grace"
  for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
}

# Sum RSS of all active handlers, walking each dispatched PID's FULL subtree
# (router shell + timeout + claude + node threads + MCP servers). On Linux this
# is cross-checked against the cgroup's own memory.current and the LARGER of the
# two is returned, so admission/back-pressure never under-counts below what
# systemd will OOM on.
get_total_child_rss_mb() {
  local total=0 pid sub
  for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
    sub=$(_subtree_rss_mb "$pid")
    total=$((total + ${sub:-0}))
  done
  # Prefer the cgroup truth when it is higher (captures overhead the subtree walk
  # cannot attribute to a tracked PID, e.g. heartbeat/ntfy/git helpers).
  local cg
  cg=$(get_cgroup_mem_mb 2>/dev/null) || cg=""
  if [[ "$cg" =~ ^[0-9]+$ ]] && [ "$cg" -gt "$total" ]; then
    total="$cg"
  fi
  echo "$total"
}

# System-wide memory-pressure gate (macOS). The cgroup OOM machinery
# (get_cgroup_mem_mb, the aggregate guard, the orphan reaper) is Linux-only and a
# NO-OP on macOS, where the bot shares a desktop with the user's apps. There the
# real killer is the kernel's jetsam: when system memory/swap runs low it SIGKILLs
# processes with NO warning and WITHOUT running our cleanup() — the exact `Killed: 9`
# at start.sh's dispatch line, observed killing a router only 16s in (before Claude
# even matured, so our own RSS watchdog never fired). check_resource_budget only
# weighs the bot's OWN subtree, so it is blind to a Mac that is already swapping hard
# because of OTHER apps. This gate adds that missing signal.
#
# Returns 0 (pressured → caller should defer) when EITHER:
#   - kern.memorystatus_vm_pressure_level >= SYSTEM_PRESSURE_LEVEL_THRESHOLD
#     (macOS levels: 1=normal, 2=warn, 4=critical; default threshold 4 = critical), or
#   - free swap has fallen below MIN_FREE_SWAP_MB (default 512).
# Linux / no sysctl → always 1 (not pressured): a pure pass-through, so the Linux
# (Linux/systemd) node's behavior is completely unchanged.
#
# Why CRITICAL (4) not WARN (2), and 512 not 2048: on a shared dev Mac level 2 is the
# steady state (the kernel just asks apps to drop caches; it does NOT jetsam-kill until
# 4), and macOS grows swap dynamically so ~1.5 GB free is normal. The old >1 / 2048 gate
# therefore deferred ~80x/hour while nothing was ever going to be killed, forcing the bot
# to 1-at-a-time and halving throughput. Both remain env-overridable for a constrained box.
SYSTEM_PRESSURE_LEVEL_THRESHOLD="${SYSTEM_PRESSURE_LEVEL_THRESHOLD:-4}"
MIN_FREE_SWAP_MB="${MIN_FREE_SWAP_MB:-512}"
SYSTEM_PRESSURE_GATE_ENABLED="${SYSTEM_PRESSURE_GATE_ENABLED:-true}"
system_memory_pressured() {
  [ "$SYSTEM_PRESSURE_GATE_ENABLED" = "true" ] || return 1
  [[ "$(uname -s)" == "Darwin" ]] || return 1   # Linux: cgroup path owns this; no-op
  command -v sysctl >/dev/null 2>&1 || return 1

  local level free_swap
  level=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null) || level=""
  if [[ "$level" =~ ^[0-9]+$ ]] && [ "$level" -ge "$SYSTEM_PRESSURE_LEVEL_THRESHOLD" ]; then
    SYSTEM_PRESSURE_REASON="vm_pressure_level=${level} (2=warn,4=critical; threshold=${SYSTEM_PRESSURE_LEVEL_THRESHOLD})"
    return 0
  fi

  # vm.swapusage → "... free = 794.06M ..." — take the integer MB.
  # Guard against sed failing to match (unexpected format/locale): if the result
  # still contains non-numeric characters (raw sysctl output passed through) or
  # equals 0 (awk coercion of garbage), treat it as a parse failure and skip the
  # check entirely rather than false-positive blocking dispatch.
  local raw_swap free_swap
  raw_swap=$(sysctl -n vm.swapusage 2>/dev/null) || raw_swap=""
  free_swap=$(echo "$raw_swap" | sed -E 's/.*free = ([0-9.]+)M.*/\1/' | awk '{printf "%d", $1}') || free_swap=""
  # Validate the parse succeeded: must be a positive integer AND must differ from
  # the raw input (sed passed it through unchanged on a non-match → awk coerced
  # the first non-numeric word to 0). A 0 result is ambiguous (genuine 0 free swap
  # vs parse failure) — require > 0 as a parse-success canary. Genuine 0 free swap
  # is extreme pressure that the vm_pressure_level check above will already catch.
  if [[ "$free_swap" =~ ^[0-9]+$ ]] && [ "$free_swap" -gt 0 ] && [ "$free_swap" -lt "$MIN_FREE_SWAP_MB" ]; then
    SYSTEM_PRESSURE_REASON="free_swap=${free_swap}MB < ${MIN_FREE_SWAP_MB}MB floor"
    return 0
  fi

  SYSTEM_PRESSURE_REASON=""
  return 1
}

# Check if we have resource budget for another job.
# Returns 0 if OK to dispatch, 1 if should defer.
# Usage: check_resource_budget [needed_mb]
check_resource_budget() {
  local needed_mb="${1:-1100}"  # default to MEDIUM weight (see weight_to_mb)
  # System-wide pressure (macOS jetsam pre-empt): defer BEFORE we add a ~1 GB Claude
  # to a host that is already swapping, which is what gets us SIGKILLed. Never starve
  # to zero — only gate when at least one session is already running, so a quiet bot
  # on a busy desktop still makes forward progress (one at a time) instead of wedging.
  if [ "${#ACTIVE_PIDS[@]}" -ge 1 ] && system_memory_pressured; then
    echo "[$(date '+%H:%M:%S')] 🛑 System memory pressure (${SYSTEM_PRESSURE_REASON}) with ${#ACTIVE_PIDS[@]} active — deferring dispatch (jetsam pre-empt)"
    return 1
  fi
  local current_mb
  current_mb=$(get_total_child_rss_mb)
  current_mb="${current_mb:-0}"
  local available_mb=$(( MEMORY_BUDGET_MB - RESERVED_OVERHEAD_MB - current_mb ))
  if [ "$available_mb" -lt "$needed_mb" ]; then
    echo "[$(date '+%H:%M:%S')] 🛑 Memory budget: need ${needed_mb}MB, only ${available_mb}MB available (current: ${current_mb}MB) — deferring"
    return 1
  fi
  return 0
}

# Per-process RSS watchdog — kills Claude processes exceeding their weight class + 50% headroom
# Associative array tracking memory budget per PID
declare -A PR_BUDGET
declare -A PR_QUEUE_FILE
# Maps dispatched router PID → PR id, so reap_jobs can read the router's true
# exit code from pr-<id>.lastexit (the `( ... || true )` wrapper hides it). Change 3.
declare -A PR_DISPATCH_ID

kill_oversized_claudes() {
  # Pass 1 — per-process watchdog: kill any single handler whose FULL-SUBTREE RSS
  # exceeds its own weight-class estimate + 50% headroom (a runaway/leaking
  # session). Measured over the whole tree (router→timeout→claude→node/MCP), not
  # just depth-1, or the ~16MB wrapper hides the ~600MB+ claude underneath it.
  for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
    kill -0 "$pid" 2>/dev/null || continue
    local rss_mb
    rss_mb=$(_subtree_rss_mb "$pid"); rss_mb="${rss_mb:-0}"
    local budget_mb="${PR_BUDGET[$pid]:-1100}"
    local limit_mb=$(( budget_mb + budget_mb / 2 ))  # 150% of estimate
    # Never kill below the fixed claude runtime baseline (~1 GB). Without this floor
    # a SMALL PR's 1050 MB limit shoots a healthy, just-matured session in the head.
    if [ "$limit_mb" -lt "$MIN_SESSION_KILL_MB" ]; then
      limit_mb="$MIN_SESSION_KILL_MB"
    fi
    if [ "$rss_mb" -gt "$limit_mb" ]; then
      echo "[$(date '+%H:%M:%S')] 🛑 Killing PR handler $pid subtree (RSS: ${rss_mb}MB > ${limit_mb}MB per-session limit, PR #${PR_DISPATCH_ID[$pid]:-unknown})"
      _kill_subtree "$pid" 5
    fi
  done

  # Pass 2 — AGGREGATE guard (the OOM stop the per-process check misses): two
  # sessions can each be UNDER their own 150% limit yet collectively breach the
  # 3G cgroup cap, which (KillMode=control-group) OOM-kills the entire bot. We
  # trigger on the AUTHORITATIVE cgroup memory.current (the exact number systemd
  # OOM-compares) when available, falling back to the subtree-sum, and shed load
  # PRE-emptively by killing the YOUNGEST live handler's whole subtree (least work
  # invested; its lease is left active so a later heartbeat re-dispatches it once
  # there is headroom). Repeat until under the mark or only one handler remains
  # (never starve the bot to zero).
  local highwater_mb=$(( (MEMORY_BUDGET_MB * 90) / 100 ))  # 90% of admission budget
  local guard_iters=0
  while [ "$guard_iters" -lt 8 ]; do
    guard_iters=$((guard_iters + 1))
    local total_mb cg_mb
    cg_mb=$(get_cgroup_mem_mb 2>/dev/null) || cg_mb=""
    if [[ "$cg_mb" =~ ^[0-9]+$ ]]; then
      total_mb="$cg_mb"
    else
      total_mb=$(get_total_child_rss_mb); total_mb="${total_mb:-0}"
    fi
    [ "$total_mb" -le "$highwater_mb" ] && break

    # Pick the youngest live handler (smallest elapsed-seconds = most recently
    # started). ps etimes is portable enough here (Linux); ties broken by PID.
    local victim="" victim_etime=-1 live=0
    for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
      kill -0 "$pid" 2>/dev/null || continue
      live=$((live + 1))
      local et
      et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
      [[ "$et" =~ ^[0-9]+$ ]] || et=999999  # Unreadable → treat as oldest (shed last, most work invested)
      # youngest = smallest etimes
      if [ "$victim_etime" -lt 0 ] || [ "$et" -lt "$victim_etime" ]; then
        victim_etime="$et"; victim="$pid"
      fi
    done
    # Never kill the last remaining handler — a single session that legitimately
    # needs >90% budget should be governed by Pass 1 / the cgroup, not starved.
    [ "$live" -le 1 ] && break
    [ -z "$victim" ] && break

    echo "[$(date '+%H:%M:%S')] 🛑 Aggregate memory guard: ${total_mb}MB > ${highwater_mb}MB high-water — shedding youngest handler $victim subtree (age ${victim_etime}s, PR #${PR_DISPATCH_ID[$victim]:-unknown}); lease stays active for re-dispatch"
    _kill_subtree "$victim" 3
    # Remove killed PID from ACTIVE_PIDS immediately so get_total_child_rss_mb
    # and the next guard iteration don't walk a dead subtree.
    local _new_active=()
    for _ap in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
      [ "$_ap" != "$victim" ] && _new_active+=("$_ap")
    done
    ACTIVE_PIDS=("${_new_active[@]+"${_new_active[@]}"}")
    unset "PR_BUDGET[$victim]" 2>/dev/null || true
    unset "PR_DISPATCH_ID[$victim]" 2>/dev/null || true
    unset "PR_QUEUE_FILE[$victim]" 2>/dev/null || true
    # Give the kernel a moment to reclaim before re-measuring the cgroup.
    sleep 1
  done
}

# --- 4th OOM-defense layer: reap leaked off-tree subprocesses ---
# THE WEDGE THIS FIXES: Claude workers shell out to az/azure.cli (python). When a
# router's session ends abnormally (timeout / OOM-shed / kill), some grandchildren
# reparent to the systemd --user manager (the daemon's parent) but STAY inside the
# pr-bot.service cgroup, so they keep counting against memory.current — yet they are
# descendants of NO tracked ACTIVE_PID, so Pass-1 (per-subtree) and Pass-2 (sheds an
# ACTIVE handler) both miss them. Left alone they accrete (~1.3GB over 2 days) until
# check_resource_budget defers ALL dispatch with ACTIVE_PIDS empty — a deadlock where
# the two existing watchdogs have nothing to act on and the leak is never reclaimed.
#
# The reaper closes that gap: it diffs the cgroup's full process list
# (cgroup.procs, the authoritative in-cgroup set — the SAME thing systemd bills to
# MemoryMax) against the daemon's own process subtree, and TERM/KILLs the leaked
# off-tree procs. The shared predicate _select_orphan_candidates (defined above,
# also used by --reap-orphans-dryrun) enforces: in-cgroup, NOT in subtree(root),
# != root/PID1, age ≥ ORPHAN_REAP_AGE_SECS, comm not denylisted.
#
# Args: root (default $$ = daemon/cgroup-root), dry_run (default 0), procs_path
# (default auto: this process's own cgroup.procs). set -e-safe (|| true, never exits);
# cgroup-v1 / non-Linux → empty procs → no-op. STDOUT carries only the 🧹 log line
# (so callers can `|| true` it straight into the journal); the reaped count is
# published via the REAP_LAST_COUNT global (avoids a command-substitution caller
# swallowing the log line or stray integers polluting the log).
REAP_LAST_COUNT=0
reap_orphaned_subprocesses() {
  REAP_LAST_COUNT=0
  [ "${ORPHAN_REAP_ENABLED:-true}" = true ] || return 0
  local root="${1:-$$}" dry_run="${2:-0}" procs_path="${3:-}"
  if [ -z "$procs_path" ]; then
    procs_path=$(get_cgroup_procs_for_pid "$root" 2>/dev/null) || procs_path=""
  fi
  [ -n "$procs_path" ] || return 0   # non-Linux / cgroup-v1 → no-op

  local candidates
  candidates=$(_select_orphan_candidates "$root" "$procs_path" 2>/dev/null) || candidates=""
  [ -n "$candidates" ] || return 0

  local count=0 reclaimed=0 pid comm age rss
  while read -r pid comm age rss; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    count=$((count + 1))
    reclaimed=$((reclaimed + ${rss:-0}))
    if [ "$dry_run" != 0 ]; then
      continue
    fi
    # Kill the orphan's WHOLE subtree (it may itself have spawned children that
    # are also off our tree). _kill_subtree is TERM children-first → grace → KILL.
    _kill_subtree "$pid" "${ORPHAN_REAP_GRACE_SECS:-5}" || true
  done <<< "$candidates"

  REAP_LAST_COUNT="$count"
  if [ "$count" -gt 0 ] && [ "$dry_run" = 0 ]; then
    echo "[$(date '+%H:%M:%S')] 🧹 Reaped ${count} orphaned subprocess(es) off-tree (~${reclaimed} MB reclaimed)"
  fi
  return 0
}

# Defer a message to the queue directory for later retry
defer_message() {
  local msg_body="$1"
  local pr_id="${2:-unknown}"
  local defer_file="${DEFER_QUEUE_DIR}/pr-${pr_id}-$(date +%s).json"
  echo "$msg_body" > "$defer_file"
  echo "[$(date '+%H:%M:%S')] 📥 Deferred PR #${pr_id} to queue ($(ls "$DEFER_QUEUE_DIR"/*.json 2>/dev/null | wc -l) queued)"
}

# Process deferred messages if resource budget allows
drain_deferred_queue() {
  [ -z "$DEFER_QUEUE_DIR" ] && return
  local queued_files
  queued_files=$(ls -tr "$DEFER_QUEUE_DIR"/*.json 2>/dev/null) || return  # -tr = OLDEST first (FIFO); -t LIFO starved the oldest entry indefinitely
  [ -z "$queued_files" ] && return

  for qfile in $queued_files; do
    [ -f "$qfile" ] || continue
    reap_jobs
    if [ "${#ACTIVE_PIDS[@]}" -ge "$MAX_CONCURRENT" ]; then
      break  # Still at concurrency limit
    fi
    if ! check_resource_budget; then
      # Deadlock-immediate reap (mirror of the dispatch path): budget exhausted with
      # zero active handlers ⇒ the memory is the orphan-leak wedge, not live work.
      # Reap off-tree orphans, re-check, and only stop draining if it STILL fails.
      # Throttled by LAST_REAP_TS (~30s); the 60s tick that calls this already reaps
      # first, so this mainly catches a wedge that forms between ticks.
      local _now_reap
      _now_reap=$(date +%s)
      if [ "${#ACTIVE_PIDS[@]}" -eq 0 ] && [[ $(( _now_reap - ${LAST_REAP_TS:-0} )) -ge 30 ]]; then
        echo "[$(date '+%H:%M:%S')] 🧹 Drain blocked with zero active handlers — reaping leaked off-tree subprocesses"
        reap_orphaned_subprocesses || true
        LAST_REAP_TS=$_now_reap
      fi
      if ! check_resource_budget; then
        break  # Memory pressure still too high
      fi
    fi
    local deferred_body
    deferred_body=$(cat "$qfile")
    rm -f "$qfile"
    echo "[$(date '+%H:%M:%S')] 📤 Draining deferred PR from queue..."
    ( "$RUNTIME_SCRIPT_DIR/pr_router.sh" "$deferred_body" || true ) &
    local handler_pid=$!
    echo "[$(date '+%H:%M:%S')] 📨 Deferred handler PID: $handler_pid"
    ACTIVE_PIDS+=($handler_pid)
    # Map PID → PR id so reap_jobs can read the router's true exit code (Change 3)
    local _dpr_id
    _dpr_id=$(echo "$deferred_body" | jq -r '.resource.pullRequest.pullRequestId // empty' 2>/dev/null) || _dpr_id=""
    PR_DISPATCH_ID[$handler_pid]="${_dpr_id:-unknown}"
    # Estimate PR weight from queued payload for OOM budget
    local _df_count _dc_count _dw
    _df_count=$(echo "$deferred_body" | jq -r '.resource.pullRequest.fileCount // 0' 2>/dev/null) || _df_count=0
    _dc_count=$(echo "$deferred_body" | jq -r '.resource.pullRequest.commentCount // 0' 2>/dev/null) || _dc_count=0
    _dw=$(estimate_pr_weight "$_df_count" "$_dc_count")
    PR_BUDGET[$handler_pid]=$(weight_to_mb "$_dw")
  done
}

# Track seen ntfy message IDs to deduplicate replayed messages on reconnect
SEEN_IDS_FILE="$STATE_DIR/seen-ntfy-ids.log"
: > "$SEEN_IDS_FILE"  # Reset on startup

# Periodic log trimming — keep last 10K lines when log exceeds 20K
LOG_MAX_LINES=20000
LOG_KEEP_LINES=10000
LAST_LOG_TRIM=0
trim_log() {
  local now
  now=$(date +%s)
  # Only check once per hour (3600s) to avoid stat overhead on every message
  if [ $((now - LAST_LOG_TRIM)) -lt 3600 ]; then
    return
  fi
  LAST_LOG_TRIM=$now
  if [ -f "$LOG_FILE" ]; then
    local line_count
    line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$line_count" -gt "$LOG_MAX_LINES" ]; then
      echo "[$(date '+%H:%M:%S')] 🔄 Trimming daemon.log ($line_count lines → last $LOG_KEEP_LINES)"
      tail -"$LOG_KEEP_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && cat "${LOG_FILE}.tmp" > "$LOG_FILE" && rm -f "${LOG_FILE}.tmp"
    fi
  fi
}

# WU7: Exponential backoff on reconnect (2s → 4s → ... → 300s max, reset on message)
RECONNECT_DELAY=2
MAX_RECONNECT_DELAY=300
PAT_FAILURE_COUNT=0

# WU11: ntfy stream liveness. The inner read loop wakes every NTFY_READ_TIMEOUT to
# run maintenance even when idle. NTFY_STALL_SECS is the half-open-connection
# watchdog: if no line (not even an ntfy keepalive) arrives for this long, the
# socket is presumed dead-but-not-EOF'd, so we tear the stream down and reconnect.
# Both env-overridable so the cadence can be tuned without a redeploy.
NTFY_READ_TIMEOUT="${NTFY_READ_TIMEOUT:-60}"
NTFY_STALL_SECS="${NTFY_STALL_SECS:-300}"

# Periodic health checks: PAT validity + stale file cleanup
# Called alongside trim_log (hourly)
periodic_health_check() {
  # ADO auth health check — detect expired tokens/PATs early
  local auth_header
  auth_header=$(get_ado_auth_header_cached 2>/dev/null) || auth_header="Basic $(echo -n ":${ADO_PAT:-}" | base64 | tr -d '\n')"
  local ado_code
  ado_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: $auth_header" \
    "https://dev.azure.com/${ADO_ORG}/_apis/projects?api-version=7.1" 2>/dev/null) || ado_code="000"
  if [[ "$ado_code" =~ ^(401|403)$ ]]; then
    PAT_FAILURE_COUNT=$((PAT_FAILURE_COUNT + 1))
    echo "[$(date '+%H:%M:%S')] ❌ ADO PAT check failed (HTTP $ado_code) — consecutive failures: $PAT_FAILURE_COUNT"
    echo "[$(date '+%H:%M:%S')] ❌ Regenerate at: https://dev.azure.com/${ADO_ORG}/_usersSettings/tokens"
  elif [[ "$ado_code" =~ ^2[0-9][0-9]$ ]]; then
    [ "$PAT_FAILURE_COUNT" -gt 0 ] && echo "[$(date '+%H:%M:%S')] ✅ ADO PAT check recovered (was failing for $PAT_FAILURE_COUNT checks)"
    PAT_FAILURE_COUNT=0
  fi

  # Stale file cleanup — remove debug output files older than 7 days
  find "$STATE_DIR" -name '*-stdout.log' -mtime +7 -delete 2>/dev/null || true
  find "$STATE_DIR" -name '*-stderr.log' -mtime +7 -delete 2>/dev/null || true
  # Remove state files for PRs that no longer have active branches (older than 30 days)
  find "$STATE_DIR" -name 'pr-*.json' -mtime +30 -delete 2>/dev/null || true
  # Circuit-breaker / exit-code state GC (Change 4): expire stale breaker streaks
  # so a long-closed PR doesn't keep a quarantine file forever, and sweep orphaned
  # lastexit markers (normally consumed by reap_jobs, but reap could miss one).
  find "$STATE_DIR" -name 'pr-*.failures' -mtime +7 -delete 2>/dev/null || true
  find "$STATE_DIR" -name 'pr-*.lastexit' -mtime +1 -delete 2>/dev/null || true
  # In-flight breadcrumbs are consumed by reap_jobs, but a SIGKILL of the DAEMON
  # itself (not just a router) can orphan one with no reaper to clear it. Sweep any
  # older than a day so a stale breadcrumb can't masquerade as a fresh hard-kill.
  find "$STATE_DIR" -name 'pr-*.inflight' -mtime +1 -delete 2>/dev/null || true
  # Foreign-lease cooldown stamps self-expire on read (seconds), but one can be
  # orphaned if its PR is closed/merged while stamped. Sweep any older than a day.
  find "$STATE_DIR" -name 'pr-*.foreign-lease' -mtime +1 -delete 2>/dev/null || true

  # Worktree GC — reap worktrees orphaned when a router was OOM/SIGKILL'd before
  # its EXIT-trap cleanup() could run `git worktree remove`. Those dirs leak
  # forever otherwise (observed: 10 stale worktrees / 1.5 GB for long-merged PRs).
  # Reuses prune_stale_worktrees() from shared/worktree.sh (also used by ci-bot/
  # cve-bot). The age threshold IS the safety gate: an actively-processed worktree
  # is written within CLAUDE_TIMEOUT (~30 min), so only dirs untouched for
  # WORKTREE_MAX_AGE_SECS (default 24h) — i.e. genuine orphans — are removed.
  if declare -f prune_stale_worktrees >/dev/null 2>&1; then
    local _wt_repo_root _wt_base _wt_pruned _wt_stderr
    # Worktrees are registered against the TARGET repo (see pr_router.sh `worktree add
    # -C "$REPO_ROOT"`), so GC them via TARGET_REPO_ROOT — NOT the harness's own repo.
    _wt_repo_root="$TARGET_REPO_ROOT"
    _wt_base="$STATE_DIR/worktrees"
    if [ -n "$_wt_repo_root" ] && [ -d "$_wt_base" ]; then
      _wt_stderr=$(mktemp)
      if _wt_pruned=$(prune_stale_worktrees "$_wt_repo_root" "$_wt_base" "${WORKTREE_MAX_AGE_SECS:-86400}" 2>"$_wt_stderr"); then
        [ "${_wt_pruned:-0}" -gt 0 ] 2>/dev/null && \
          echo "[$(date '+%H:%M:%S')] 🧹 Pruned ${_wt_pruned} stale worktree(s) (orphaned by OOM/SIGKILL)"
      else
        echo "[$(date '+%H:%M:%S')] ⚠️  Worktree GC failed (exit $?): $(cat "$_wt_stderr" 2>/dev/null)"
      fi
      rm -f "$_wt_stderr"
      # Fast path: worktrees are keyed pr-<ID>-<PID>, so a dead-PID suffix is an
      # unambiguous orphan (router SIGKILL'd before cleanup) — reclaim it NOW rather
      # than waiting out the 24h age gate. Critical on this memory-pressured macOS
      # node where jetsam SIGKILLs leave a uniquely-named orphan on every kill.
      if declare -f prune_dead_pid_worktrees >/dev/null 2>&1; then
        local _wt_dead
        _wt_dead=$(prune_dead_pid_worktrees "$_wt_repo_root" "$_wt_base" 2>/dev/null) || _wt_dead=0
        [ "${_wt_dead:-0}" -gt 0 ] 2>/dev/null && \
          echo "[$(date '+%H:%M:%S')] 🧹 Pruned ${_wt_dead} dead-PID worktree(s) (router killed before cleanup)"
      fi
    fi
  fi

  # Self-heal during multi-day uptime: re-run crash recovery periodically (not just
  # at startup) so .crashed markers written mid-run are processed without a restart.
  # recover_crashed_prs self-guards (reentrancy lock + lease re-check). Background
  # so it never blocks the reconnect path that calls periodic_health_check.
  recover_crashed_prs &
}

# --- Crash recovery: detect .crashed files from previous runs ---
# Posts a notice on the PR and cleans up, running in background so it
# doesn't block the ntfy subscribe loop.
recover_crashed_prs() {
  # Reentrancy guard (Change 4): startup recovery and the periodic re-run can
  # overlap, so allow only one pass at a time via a lock dir. Mirrors the per-PR
  # .lock idiom (start.sh dispatch path): the lock dir holds a `pid` file
  # (`timestamp\n$$`), and a lock whose holder PID is dead (per `kill -0`) is
  # reclaimed. PID-liveness — not a fixed age — avoids both false "stale"
  # reclaims during a long legitimate pass and indefinite hangs after a kill.
  local _recover_lock="$STATE_DIR/.recover.lock"
  if ! mkdir "$_recover_lock" 2>/dev/null; then
    local _rl_pid
    _rl_pid=$(sed -n '2p' "$_recover_lock/pid" 2>/dev/null || echo 0)
    if [ "${_rl_pid:-0}" -gt 0 ] 2>/dev/null && kill -0 "$_rl_pid" 2>/dev/null; then
      return  # Another recovery pass is active
    fi
    echo "[$(date '+%H:%M:%S')] 🔧 Reclaiming stale recovery lock (holder PID ${_rl_pid:-0} dead)"
    rm -f "$_recover_lock/pid" 2>/dev/null
    rmdir "$_recover_lock" 2>/dev/null || true
    mkdir "$_recover_lock" 2>/dev/null || return
  fi
  printf '%s\n%s\n' "$(date +%s)" "$$" > "$_recover_lock/pid" 2>/dev/null || true
  # NOTE: release the lock EXPLICITLY at every return point below — do NOT use a
  # `trap ... RETURN` here. This function `source`s files (ado_auth.sh) mid-pass,
  # and a bash RETURN trap fires on each sourced-file completion, which would
  # release the lock before the pass finishes (defeating the reentrancy guard).

  local crashed_files
  crashed_files=$(ls "$STATE_DIR"/pr-*.crashed 2>/dev/null) || true
  if [ -z "$crashed_files" ]; then
    rm -f "$_recover_lock/pid" 2>/dev/null; rmdir "$_recover_lock" 2>/dev/null || true
    return
  fi

  echo "[$(date '+%H:%M:%S')] 🔧 Found crashed PR markers, starting recovery..."

  for crash_file in $crashed_files; do
    [ -f "$crash_file" ] || continue

    local crash_info
    crash_info=$(cat "$crash_file" 2>/dev/null) || { rm -f "$crash_file"; continue; }

    local cr_pr cr_code cr_ts cr_host cr_repo cr_lease_thread cr_lease_comment cr_lease_expires
    # GUARD: a crash-file truncated mid-write (the host died while writing it) is not valid
    # JSON, so jq exits 5. A separate-line `VAR=$(...)` is still subject to `set -e` (only an
    # inline `local VAR=$(...)` would mask it), so each needs an explicit `|| VAR=default`.
    cr_pr=$(echo "$crash_info" | jq -r '.pr // empty' 2>/dev/null) || cr_pr=""
    cr_code=$(echo "$crash_info" | jq -r '.exitCode // "unknown"' 2>/dev/null) || cr_code="unknown"
    cr_ts=$(echo "$crash_info" | jq -r '.timestamp // "unknown"' 2>/dev/null) || cr_ts="unknown"
    cr_host=$(echo "$crash_info" | jq -r '.host // "unknown"' 2>/dev/null) || cr_host="unknown"
    cr_repo=$(echo "$crash_info" | jq -r '.repoId // empty' 2>/dev/null) || cr_repo=""
    cr_lease_thread=$(echo "$crash_info" | jq -r '.leaseThreadId // empty' 2>/dev/null) || cr_lease_thread=""
    cr_lease_comment=$(echo "$crash_info" | jq -r '.leaseCommentId // empty' 2>/dev/null) || cr_lease_comment=""
    cr_lease_expires=$(echo "$crash_info" | jq -r '.leaseExpires // 0' 2>/dev/null) || cr_lease_expires=0

    [ -z "$cr_pr" ] && { rm -f "$crash_file"; continue; }

    echo "[$(date '+%H:%M:%S')] 🔧 Recovering PR #${cr_pr} (crashed on ${cr_host}, exit code ${cr_code})"

    # Wait until the lease has expired before posting (avoid conflicting with active processing)
    local now wait_until wait_secs
    now=$(date +%s)
    wait_until=$((cr_lease_expires + 60))
    wait_secs=$((wait_until - now))
    if [ "$wait_secs" -gt 0 ]; then
      # Cap wait to 35 minutes to avoid indefinite hangs
      [ "$wait_secs" -gt 2100 ] && wait_secs=2100
      echo "[$(date '+%H:%M:%S')] 🔧 PR #${cr_pr}: waiting ${wait_secs}s for lease expiry..."
      sleep "$wait_secs"
    fi

    # Re-check: if another bot already picked up this PR, skip
    if [ -n "$cr_repo" ] && [ -n "$cr_lease_thread" ]; then
      # Source lease functions for check_pr_lease
      local ADO_BASE="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis"
      local PR_THREADS_JSON=""
      local EXISTING_LEASE_HOST=""
      # Portable base64
      b64_encode() { base64 | tr -d '\n'; }
      # Source auth helper for recovery
      if [ -f "$SCRIPT_DIR/../shared/ado_auth.sh" ]; then
        source "$SCRIPT_DIR/../shared/ado_auth.sh"
      fi
      local _auth_header
      _auth_header=$(get_ado_auth_header_cached 2>/dev/null) || _auth_header="Basic $(echo -n ":${ADO_PAT:-}" | b64_encode)"
      # Minimal ado_api_call for recovery (reuse from sourced scripts)
      local check_response
      check_response=$(curl -s --max-time 15 \
        -H "Authorization: $_auth_header" \
        "${ADO_BASE}/git/repositories/${cr_repo}/pullRequests/${cr_pr}/threads?api-version=7.1" 2>/dev/null) || true

      if [ -n "$check_response" ]; then
        local active_lease
        # GUARD: $check_response is the raw ADO threads API body, which can be a non-JSON
        # 503/"Services Unavailable" HTML page (observed live) → jq exits 5 → `set -e`.
        # Trade-off: the `|| active_lease=""` fallback then skips the lease check and proceeds
        # to recovery — the safe default (never strands a stuck PR), at the cost of a possible
        # duplicate recovery across pods during a transient ADO outage (benign: downstream is idempotent).
        active_lease=$(echo "$check_response" | jq -r --argjson now "$(date +%s)" --argjson grace 60 '
          [.value[]
           | .comments[]?
           | .content // ""
           | capture("<!-- pr-bot-lease:(?<json>\\{[^}]+\\}) -->")
           | .json | fromjson
           | select(.expires + $grace > $now)
           | select(.status != "done" and .status != "failed")
          ] | first // empty' 2>/dev/null) || active_lease=""

        if [ -n "$active_lease" ]; then
          echo "[$(date '+%H:%M:%S')] 🔧 PR #${cr_pr}: another bot has active lease, skipping recovery"
          rm -f "$crash_file"
          continue
        fi
      fi

      # Post crash notice on the status thread
      if [ -n "$cr_lease_thread" ] && [ -n "$cr_lease_comment" ]; then
        local notice_content
        notice_content="⚠️ **Left Jab Bot**: Crashed on \`${cr_host}\` (exit code ${cr_code}) at ${cr_ts}. The PR was not fully processed. Re-trigger by pushing a commit or re-opening a review thread."
        local notice_body
        notice_body=$(jq -n --arg c "$notice_content" '{content:$c,parentCommentId:1,commentType:1}') || notice_body=""
        # GUARD: if jq failed, $notice_body is empty — POSTing it would silently drop the
        # crash notice (a no-op the "posted" log would falsely claim succeeded). Skip + warn instead.
        if [ -n "$notice_body" ]; then
          curl -s --max-time 15 \
            -X POST \
            -H "Authorization: $_auth_header" \
            -H "Content-Type: application/json" \
            -d "$notice_body" \
            "${ADO_BASE}/git/repositories/${cr_repo}/pullRequests/${cr_pr}/threads/${cr_lease_thread}/comments?api-version=7.1" >/dev/null 2>&1 || true
          echo "[$(date '+%H:%M:%S')] 🔧 PR #${cr_pr}: posted crash notice on status thread"
        else
          echo "[$(date '+%H:%M:%S')] ⚠️  PR #${cr_pr}: skipped crash notice — failed to build notice body (jq error)"
        fi
      fi
    fi

    rm -f "$crash_file"
    echo "[$(date '+%H:%M:%S')] 🔧 PR #${cr_pr}: recovery complete"
  done

  # Explicit lock release (see the RETURN-trap note above — do not convert this
  # to a trap). The in-loop `continue`s keep the lock held until the pass ends.
  rm -f "$_recover_lock/pid" 2>/dev/null
  rmdir "$_recover_lock" 2>/dev/null || true
}

# Run crash recovery in background so it doesn't block the ntfy loop
recover_crashed_prs &

# --- Replay persisted message queue from previous crash/restart ---
replay_queued_messages() {
  local count=0
  for qf in "$QUEUE_DIR"/*.json; do
    [ -f "$qf" ] || continue
    local age=$(( $(date +%s) - $(stat -c %Y "$qf" 2>/dev/null || echo 0) ))
    if [ "$age" -gt 86400 ]; then
      echo "[$(date '+%H:%M:%S')] 🧹 Discarding stale queue file (${age}s old): $(basename "$qf")"
      rm -f "$qf"
      continue
    fi
    reap_jobs
    if [ "${#ACTIVE_PIDS[@]}" -ge "$MAX_CONCURRENT" ]; then
      echo "[$(date '+%H:%M:%S')] ⏳ Queue replay stopped — concurrency limit reached"
      break
    fi
    if ! check_resource_budget; then
      echo "[$(date '+%H:%M:%S')] ⏳ Queue replay stopped — memory pressure"
      break
    fi
    local replay_body
    replay_body=$(cat "$qf")
    local replay_pr_id
    # GUARD: a queue file persisted by a host that died mid-write can be truncated/non-JSON.
    # replay_queued_messages runs in the FOREGROUND at startup, so an unguarded jq exit 5 here
    # would kill the daemon on every relaunch → a crash-loop that never drains the bad file.
    replay_pr_id=$(echo "$replay_body" | jq -r '.resource.pullRequest.pullRequestId // empty' 2>/dev/null) || replay_pr_id=""
    echo "[$(date '+%H:%M:%S')] 🔄 Replaying queued message for PR #${replay_pr_id:-unknown}"
    ( "$RUNTIME_SCRIPT_DIR/pr_router.sh" "$replay_body" || true ) &
    local handler_pid=$!
    ACTIVE_PIDS+=($handler_pid)
    # Map PID → PR id so reap_jobs can read the router's true exit code (Change 3)
    PR_DISPATCH_ID[$handler_pid]="${replay_pr_id:-unknown}"
    # Estimate PR weight from queued payload for OOM budget
    local _rf_count _rc_count _rw
    _rf_count=$(echo "$replay_body" | jq -r '.resource.pullRequest.fileCount // 0' 2>/dev/null) || _rf_count=0
    _rc_count=$(echo "$replay_body" | jq -r '.resource.pullRequest.commentCount // 0' 2>/dev/null) || _rc_count=0
    _rw=$(estimate_pr_weight "$_rf_count" "$_rc_count")
    PR_BUDGET[$handler_pid]=$(weight_to_mb "$_rw")
    PR_QUEUE_FILE[$handler_pid]="$qf"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && echo "[$(date '+%H:%M:%S')] 🔄 Replayed $count queued message(s)" || true
}
replay_queued_messages

# --- Start heartbeat for orphan PR recovery ---
"$RUNTIME_SCRIPT_DIR/pr_heartbeat.sh" &
HEARTBEAT_PID=$!
echo "[$(date '+%H:%M:%S')] 🫀 Heartbeat started (PID: $HEARTBEAT_PID, interval: ${HEARTBEAT_INTERVAL_SECS:-300}s)"

# Update cleanup to also kill heartbeat (redefines the earlier function)
cleanup() {
  echo ""
  echo "👋 PR Bot stopping — waiting for active jobs..."
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "👋 PR Bot stopped"
  exit 0
}

# Subscribe using ntfy's streaming JSON endpoint for reliable delivery.
# This keeps a persistent HTTP connection open — ntfy pushes each event
# as a newline-delimited JSON object as it arrives, with no polling gaps.
LAST_DRAIN_TIME=$(date +%s)
LAST_REAP_TS=0   # throttle for the deadlock-immediate orphan reap (dispatch + drain paths)
while true; do
  # WU6: Use process substitution instead of pipe to avoid subshell variable scoping.
  # This ensures ACTIVE_PIDS updates propagate to the main shell.
  # WU11: read -t wakes us every NTFY_READ_TIMEOUT for maintenance. Bash read exit
  # codes: 0 = line read; 1 = EOF (stream closed → curl died, MUST reconnect);
  # >128 = -t timeout (stream still open, just idle → keep waiting). The previous
  # guard `|| [ $? -le 128 ]` was INVERTED: it looped forever burning CPU on EOF
  # (the real disconnect) and broke out on a healthy idle timeout. We now capture
  # the code explicitly (set -e safe) and only stay in the inner loop on success
  # (rc 0) or timeout (rc >128); any EOF (rc 1..128) breaks out to the reconnect.
  LAST_EVENT_TIME=$(date +%s)
  while true; do
    set +e
    IFS= read -r -t "$NTFY_READ_TIMEOUT" msg
    _read_rc=$?
    set -e
    if [ "$_read_rc" -gt 128 ]; then
      # -t timeout: stream open but idle. Watchdog for half-open sockets that
      # never deliver EOF — if even ntfy keepalives have stopped for too long,
      # presume the connection is dead and force a reconnect.
      _now=$(date +%s)
      if [ $((_now - LAST_EVENT_TIME)) -ge "$NTFY_STALL_SECS" ]; then
        echo "[$(date '+%H:%M:%S')] 🩺 ntfy stream silent ${NTFY_STALL_SECS}s (no keepalive) — forcing reconnect"
        break
      fi
      msg=""
    elif [ "$_read_rc" -ne 0 ]; then
      # EOF (rc 1..128): curl/stream closed. Break out to the reconnect logic.
      break
    fi

    # Periodic maintenance — drain heartbeat-queued work every 60s even when busy
    _now=$(date +%s)
    if [ $((_now - LAST_DRAIN_TIME)) -ge 60 ]; then
      LAST_DRAIN_TIME=$_now
      # Reap leaked off-tree subprocesses FIRST (frees cgroup memory the leak holds)
      # so the subsequent drain's admission check sees the reclaimed headroom. This
      # tick bypasses the LAST_REAP_TS throttle (it's already rate-limited to 60s).
      reap_orphaned_subprocesses || true
      LAST_REAP_TS=$_now
      drain_deferred_queue || true
      kill_oversized_claudes || true
    fi

    # On read timeout (empty msg), just continue to next iteration
    if [ -z "${msg:-}" ]; then
      continue
    fi

    # A line arrived (event or ntfy keepalive) — the stream is demonstrably
    # alive, so reset the stall watchdog.
    LAST_EVENT_TIME=$_now

    # ntfy wraps messages — extract the actual message body.
    # GUARD: a bare `VAR=$(... | jq ...)` exits 5 when jq gets non-JSON (e.g. an
    # ntfy/ADO 503 HTML error page on the stream — observed live). Under `set -euo
    # pipefail` that non-zero exit kills the daemon parent (silent exit 5). `2>/dev/null`
    # only hides jq's stderr; it does NOT neutralise the exit code, so an explicit
    # `|| VAR=""` is required on every top-level jq assignment in this loop.
    MSG_TYPE=$(echo "$msg" | jq -r '.event // empty' 2>/dev/null) || MSG_TYPE=""
    [ "$MSG_TYPE" != "message" ] && continue

    # WU7: Reset backoff on successful message receipt
    RECONNECT_DELAY=2

    # Deduplicate — ntfy replays cached messages on reconnect
    # Lockless check — worst case a duplicate slips through, but downstream layers catch it
    NTFY_MSG_ID=$(echo "$msg" | jq -r '.id // empty' 2>/dev/null) || NTFY_MSG_ID=""
    if [ -n "$NTFY_MSG_ID" ]; then
      if grep -qxF "$NTFY_MSG_ID" "$SEEN_IDS_FILE" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏭️  Skipping duplicate ntfy message: $NTFY_MSG_ID"
        continue
      fi
      echo "$NTFY_MSG_ID" >> "$SEEN_IDS_FILE"
      # Prune to last 500 entries periodically
      if [ "$(wc -l < "$SEEN_IDS_FILE" 2>/dev/null || echo 0)" -gt 600 ]; then
        tail -500 "$SEEN_IDS_FILE" > "${SEEN_IDS_FILE}.tmp" && mv "${SEEN_IDS_FILE}.tmp" "$SEEN_IDS_FILE"
      fi
    fi

    # Check if ntfy stored the payload as a file attachment (large ADO webhooks)
    ATTACHMENT_URL=$(echo "$msg" | jq -r '.attachment.url // empty' 2>/dev/null) || ATTACHMENT_URL=""
    if [ -n "$ATTACHMENT_URL" ]; then
      # ntfy behind /ntfy prefix generates /file/ URLs missing the prefix — rewrite using configured NTFY_URL
      NTFY_BASE="${NTFY_URL%/ntfy}"  # e.g. https://ntfy.example.com
      ATTACHMENT_URL=$(echo "$ATTACHMENT_URL" | sed "s|${NTFY_BASE}/file/|${NTFY_BASE}/ntfy/file/|" | sed "s|/ntfy/ntfy/|/ntfy/|")
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📎 Attachment detected, fetching: $ATTACHMENT_URL"
      TMPFILE=$(mktemp /tmp/pr-bot-attachment.XXXXXX)
      HDRFILE=$(mktemp /tmp/pr-bot-headers.XXXXXX)
      ATTACH_OK=false
      ATTACH_RETRIES=3
      ATTACH_BACKOFF=2
      for _att_i in $(seq 1 $ATTACH_RETRIES); do
        HTTP_CODE=$(curl -s --max-time 10 -o "$TMPFILE" -D "$HDRFILE" -w '%{http_code}' "$ATTACHMENT_URL" 2>/dev/null) || HTTP_CODE="000"
        if [ "$HTTP_CODE" = "200" ] && [ -s "$TMPFILE" ]; then
          ATTACH_OK=true
          break
        elif [ "$HTTP_CODE" = "429" ]; then
          # Parse Retry-After header (integer seconds), default to backoff value
          RETRY_AFTER=$(grep -i '^retry-after:' "$HDRFILE" 2>/dev/null | head -1 | tr -d '\r' | awk '{print $2}')
          # Validate it's a positive integer, fall back to backoff if not (e.g. HTTP-date format)
          if ! [[ "$RETRY_AFTER" =~ ^[0-9]+$ ]]; then
            RETRY_AFTER="$ATTACH_BACKOFF"
          fi
          # Sanity-cap at 120s
          [ "$RETRY_AFTER" -gt 120 ] && RETRY_AFTER=120
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  Attachment fetch 429 (attempt $_att_i/$ATTACH_RETRIES), Retry-After: ${RETRY_AFTER}s"
          sleep "$RETRY_AFTER"
        elif [[ "$HTTP_CODE" =~ ^5[0-9][0-9]$ ]] || [ "$HTTP_CODE" = "000" ]; then
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  Attachment fetch HTTP $HTTP_CODE (attempt $_att_i/$ATTACH_RETRIES), retrying in ${ATTACH_BACKOFF}s..."
          sleep "$ATTACH_BACKOFF"
          ATTACH_BACKOFF=$((ATTACH_BACKOFF * 2))
        else
          # Permanent error (4xx except 429) — skip immediately
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Attachment fetch permanent error (HTTP $HTTP_CODE), skipping"
          break
        fi
      done
      rm -f "$HDRFILE"
      if [ "$ATTACH_OK" = true ]; then
        MSG_BODY=$(cat "$TMPFILE")
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Failed to fetch attachment after $ATTACH_RETRIES attempts (last HTTP $HTTP_CODE) from $ATTACHMENT_URL"
        rm -f "$TMPFILE"
        continue
      fi
      rm -f "$TMPFILE"
    else
      MSG_BODY=$(echo "$msg" | jq -r '.message // empty' 2>/dev/null) || MSG_BODY=""
    fi
    [ -z "$MSG_BODY" ] && continue

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Filter completed/abandoned PRs from webhook payload (zero API calls — status is in the payload)
    PAYLOAD_PR_STATUS=$(echo "$MSG_BODY" | jq -r '.resource.pullRequest.status // .resource.status // empty' 2>/dev/null) || PAYLOAD_PR_STATUS=""
    if [ "$PAYLOAD_PR_STATUS" = "completed" ] || [ "$PAYLOAD_PR_STATUS" = "abandoned" ]; then
      echo "[$TIMESTAMP] ⏭️  Skipping non-active PR (status: $PAYLOAD_PR_STATUS from webhook payload)"
      continue
    fi

    # Break the lease-comment self-trigger loop (zero API calls — content is in the payload).
    # The bot authenticates via PAT, so when a router PATCHes its OWN lease/status comment
    # (acquire_pr_lease bumps the iteration counter; release_pr_lease marks done/failed),
    # ADO fires a `git-pullrequest-comment-event` for that edit → ntfy → here. Each carries a
    # fresh notificationId so the dedup log can't catch it, and dispatching a router just
    # re-stamps the lease → another edit event → infinite tight loop (observed: 54 dispatches
    # in 11 min on one PR, burning CPU while the PR "appears stuck"). The machine markers
    # (pr-bot-lease / pr-bot-status) are bot-internal and never require the bot to act, so
    # drop these events at intake. Human/review comments never carry these markers.
    PAYLOAD_COMMENT_CONTENT=$(echo "$MSG_BODY" | jq -r '.resource.comment.content // empty' 2>/dev/null) || PAYLOAD_COMMENT_CONTENT=""
    case "$PAYLOAD_COMMENT_CONTENT" in
      *pr-bot-lease*|*pr-bot-status*)
        echo "[$TIMESTAMP] ⏭️  Skipping self-authored bot lease/status comment edit (no-op event, prevents self-trigger loop)"
        continue
        ;;
    esac

    # Foreign-lease cooldown coalescing (zero API). The self-edit filter above only
    # catches our OWN lease-comment edits. When ANOTHER host is driving
    # a PR, ADO emits a stream of genuine events for it (foreign pushes, build-status
    # updates) — each a fresh notificationId, so neither dedup nor the content filter
    # stops them. Each used to spawn a router that paid two ADO calls to rediscover
    # the foreign lease and exit 0 (observed: PR #1404 — 7 routers in 14s). A router
    # that hits a foreign lease drops a short-lived $STATE_DIR/pr-<ID>.foreign-lease
    # stamp (epoch-of-expiry); while it is fresh, coalesce further events for that PR
    # here instead of dispatching. The heartbeat path does NOT consult this stamp, so
    # authoritative ~5-min recovery is preserved. Expired stamps are removed on read.
    _FL_PR_ID=$(echo "$MSG_BODY" | jq -r '.resource.pullRequest.pullRequestId // empty' 2>/dev/null) || _FL_PR_ID=""
    # Defense-in-depth: ADO PR IDs are always bare integers, but _FL_PR_ID is
    # interpolated straight into a file path below, so reject any non-numeric value
    # (malformed/replayed webhook) to prevent path traversal (e.g. "../../etc/...").
    # A rejected value is treated as "no stamp to consult".
    case "$_FL_PR_ID" in ''|*[!0-9]*) _FL_PR_ID="" ;; esac
    if [ -n "$_FL_PR_ID" ] && [ -f "$STATE_DIR/pr-${_FL_PR_ID}.foreign-lease" ]; then
      _fl_expiry=$(cat "$STATE_DIR/pr-${_FL_PR_ID}.foreign-lease" 2>/dev/null || echo 0)
      if [ "${_fl_expiry:-0}" -gt "$(date +%s)" ] 2>/dev/null; then
        echo "[$TIMESTAMP] ⏭️  PR #${_FL_PR_ID} under foreign-lease cooldown (held by another host), coalescing"
        continue
      else
        # Reached when the stamp expired normally OR is corrupt/truncated (an empty or
        # non-numeric expiry fails the -gt test via its 2>/dev/null and falls through
        # here). Recovery is identical — drop the stamp — but log so operators can tell
        # a normal expiry apart from a corrupt-stamp cleanup.
        echo "[$TIMESTAMP] 🧊 PR #${_FL_PR_ID} foreign-lease stamp expired/cleared (expiry='${_fl_expiry}'), removing — will dispatch normally"
        rm -f "$STATE_DIR/pr-${_FL_PR_ID}.foreign-lease" 2>/dev/null || true
      fi
    fi

    if [ "$DRY_RUN" = true ]; then
      echo "[$TIMESTAMP] [DRY-RUN] $(echo "$MSG_BODY" | jq -c . 2>/dev/null || echo "$MSG_BODY")"
    else
      # Enforce concurrency limit. MUST be a `while`, not an `if`: `wait -n` can
      # wake on ANY background job (the heartbeat loop, the watchdog pinger), not
      # necessarily a router finishing — so a single if+reap could fall through
      # still at the cap and dispatch MAX_CONCURRENT+1. Loop until reap_jobs
      # confirms a slot actually freed.
      reap_jobs
      _conc_logged=false
      while [ "${#ACTIVE_PIDS[@]}" -ge "$MAX_CONCURRENT" ]; do
        if [ "$_conc_logged" = false ]; then
          echo "[$TIMESTAMP] ⏳ Concurrency limit ($MAX_CONCURRENT) reached, waiting..."
          _conc_logged=true
        fi
        wait -n 2>/dev/null || true
        reap_jobs
      done

      # Resource-aware backpressure: defer if memory pressure is too high
      if ! check_resource_budget; then
        # Deadlock-immediate reap: if the budget is exhausted but NO handler is
        # active, the memory can't belong to live work — it's the orphan-leak wedge
        # (leaked az/python grandchildren in-cgroup but off our subtree). The two
        # watchdog passes can't help here (they only act on ACTIVE_PIDS). Reap the
        # orphans, then re-check budget and dispatch if it now clears, instead of
        # deferring into the same unbreakable wedge. Throttled by LAST_REAP_TS (~30s)
        # so a message burst can't reap-spam; the 60s maintenance tick bypasses this.
        _now_reap=$(date +%s)
        if [ "${#ACTIVE_PIDS[@]}" -eq 0 ] && [[ $(( _now_reap - ${LAST_REAP_TS:-0} )) -ge 30 ]]; then
          echo "[$TIMESTAMP] 🧹 Budget exhausted with zero active handlers — reaping leaked off-tree subprocesses before deferring"
          reap_orphaned_subprocesses || true
          LAST_REAP_TS=$_now_reap
        fi
        if ! check_resource_budget; then
          _DEFER_PR_ID=$(echo "$MSG_BODY" | jq -r '.resource.pullRequest.pullRequestId // empty' 2>/dev/null) || true
          defer_message "$MSG_BODY" "${_DEFER_PR_ID:-unknown}"
          continue
        fi
      fi

      # #25: sample the aggregate OOM guard in the HOT path (throttled), not only
      # on stream-disconnect. A burst of session completions plus a fresh spike
      # can breach the 90% high-water between disconnects (observed 3071MB
      # near-miss). This runs in the MAIN shell so ACTIVE_PIDS/PR_BUDGET are live
      # — a backgrounded subshell would only see a fork-time copy and shed
      # nothing. Throttled to >=10s so a message burst can't make it expensive.
      _now_guard=$(date +%s)
      if [ $(( _now_guard - ${LAST_GUARD_TS:-0} )) -ge 10 ]; then
        _guard_start_ns=$(date +%s%N 2>/dev/null || echo 0)
        kill_oversized_claudes || true
        _guard_end_ns=$(date +%s%N 2>/dev/null || echo 0)
        if [[ "$_guard_start_ns" =~ ^[0-9]+$ ]] && [[ "$_guard_end_ns" =~ ^[0-9]+$ ]]; then
          _guard_ms=$(( (_guard_end_ns - _guard_start_ns) / 1000000 ))
          [ "$_guard_ms" -gt 200 ] && echo "[$(date '+%H:%M:%S')] ⚠️  Memory guard took ${_guard_ms}ms (>${#ACTIVE_PIDS[@]} active sessions)"
        fi
        LAST_GUARD_TS=$_now_guard
      fi
      echo "[$TIMESTAMP] 📨 Received PR event, dispatching to router..."
      echo "[$TIMESTAMP] 📨 MSG_BODY size: ${#MSG_BODY} bytes"

      # Early coalescing: if this PR is already locked (being processed), skip dispatch entirely.
      # This avoids spawning router processes that will just hit the lock and exit.
      # Auto-cleans stale locks where the holder PID is dead or the lock has expired.
      # The age check guards against PID reuse on long-running systems.
      _EARLY_PR_ID=$(echo "$MSG_BODY" | jq -r '.resource.pullRequest.pullRequestId // empty' 2>/dev/null) || true
      if [ -n "$_EARLY_PR_ID" ] && [ -d "$STATE_DIR/pr-${_EARLY_PR_ID}.lock" ]; then
        _lock_ts=$(head -1 "$STATE_DIR/pr-${_EARLY_PR_ID}.lock/pid" 2>/dev/null || echo 0)
        _lock_pid=$(sed -n '2p' "$STATE_DIR/pr-${_EARLY_PR_ID}.lock/pid" 2>/dev/null || echo 0)
        _lock_age=$(( $(date +%s) - ${_lock_ts:-0} ))
        _lock_max_age=$(( ${CLAUDE_TIMEOUT:-1800} + 120 ))  # CLAUDE_TIMEOUT + 2min grace

        if [ "$_lock_age" -gt "$_lock_max_age" ]; then
          # Lock expired by age — PID may have been recycled, force cleanup
          echo "[$TIMESTAMP] 🧹 Cleaning expired lock for PR #${_EARLY_PR_ID} (age: ${_lock_age}s > max: ${_lock_max_age}s, PID $_lock_pid)"
          rm -f "$STATE_DIR/pr-${_EARLY_PR_ID}.lock/pid" 2>/dev/null
          rmdir "$STATE_DIR/pr-${_EARLY_PR_ID}.lock" 2>/dev/null || true
        elif [ "$_lock_pid" -gt 0 ] 2>/dev/null && kill -0 "$_lock_pid" 2>/dev/null; then
          echo "[$TIMESTAMP] ⏭️  PR #${_EARLY_PR_ID} already locked (PID $_lock_pid alive, age: ${_lock_age}s), coalescing"
          continue
        else
          # Lock holder is dead — clean up stale lock and proceed to dispatch
          echo "[$TIMESTAMP] 🧹 Cleaning stale lock for PR #${_EARLY_PR_ID} (PID $_lock_pid dead, age: ${_lock_age}s)"
          rm -f "$STATE_DIR/pr-${_EARLY_PR_ID}.lock/pid" 2>/dev/null
          rmdir "$STATE_DIR/pr-${_EARLY_PR_ID}.lock" 2>/dev/null || true
        fi
      fi

      [[ "$VERBOSE" == "true" ]] && echo "[$TIMESTAMP] 📨 ntfy envelope keys: $(echo "$msg" | jq -r 'keys | join(", ")' 2>/dev/null)"
      [[ "$VERBOSE" == "true" ]] && echo "[$TIMESTAMP] 📨 ntfy raw envelope: $(echo "$msg" | jq -c . 2>/dev/null || echo "$msg")"
      [[ "$VERBOSE" == "true" ]] && echo "[$TIMESTAMP] 📨 MSG_BODY (first 500 chars): $(echo "$MSG_BODY" | head -c 500)"
      [[ "$VERBOSE" == "true" ]] && echo "  Payload: $(echo "$MSG_BODY" | jq -c . 2>/dev/null || echo "$MSG_BODY")"
      [[ "$VERBOSE" == "true" ]] && echo "  Payload preview: $(echo "$MSG_BODY" | head -c 200)"
      # Wrap router in a subshell that always exits 0 — prevents set -e in the
      # main loop from killing start.sh when a router exits non-zero (e.g. during
      # worktree cleanup, Claude timeout, or any set -e triggered exit in the router).
      # The router handles its own error reporting; the main loop just needs to keep running.

      # Persist message to queue for crash recovery
      _QUEUE_PR_ID=$(echo "$MSG_BODY" | jq -r '.resource.pullRequest.pullRequestId // empty' 2>/dev/null) || true
      _queue_file="$QUEUE_DIR/$(date +%s%N)-pr-${_QUEUE_PR_ID:-unknown}.json"
      echo "$MSG_BODY" > "$_queue_file"

      ( "$RUNTIME_SCRIPT_DIR/pr_router.sh" "$MSG_BODY" || true ) &
      HANDLER_PID=$!
      echo "[$TIMESTAMP] 📨 Handler PID: $HANDLER_PID for payload (${#MSG_BODY} bytes)"
      ACTIVE_PIDS+=($HANDLER_PID)
      # Map PID → PR id so reap_jobs can read the router's true exit code (Change 3)
      PR_DISPATCH_ID[$HANDLER_PID]="${_QUEUE_PR_ID:-unknown}"
      # Estimate PR weight from payload metadata for OOM budget
      _pr_file_count=$(echo "$MSG_BODY" | jq -r '.resource.pullRequest.fileCount // 0' 2>/dev/null) || _pr_file_count=0
      _pr_comment_count=$(echo "$MSG_BODY" | jq -r '.resource.pullRequest.commentCount // 0' 2>/dev/null) || _pr_comment_count=0
      _pr_weight=$(estimate_pr_weight "$_pr_file_count" "$_pr_comment_count")
      PR_BUDGET[$HANDLER_PID]=$(weight_to_mb "$_pr_weight")
      PR_QUEUE_FILE[$HANDLER_PID]="$_queue_file"
    fi
  done < <(curl -s --no-buffer --keepalive-time 30 "${NTFY_URL}/${TOPIC}/json" 2>/dev/null)

  # Connection dropped — reconnect with exponential backoff (WU7)
  echo "[$(date '+%H:%M:%S')] ⚡ Stream disconnected, reconnecting in ${RECONNECT_DELAY}s..."
  trim_log || true
  periodic_health_check || true
  reap_orphaned_subprocesses || true
  kill_oversized_claudes || true
  drain_deferred_queue || true
  sleep "$RECONNECT_DELAY"
  RECONNECT_DELAY=$(( RECONNECT_DELAY * 2 ))
  [ "$RECONNECT_DELAY" -gt "$MAX_RECONNECT_DELAY" ] && RECONNECT_DELAY=$MAX_RECONNECT_DELAY
done
