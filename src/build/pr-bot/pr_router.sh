#!/usr/bin/env bash
set -euo pipefail

# pr_router.sh — Orchestrator for PR comment events
# Called by start.sh with raw ADO webhook JSON as $1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERBOSE="${VERBOSE:-false}"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.pr-bot-state}"
WORKTREE_DIR="${STATE_DIR}/worktrees"
mkdir -p "$WORKTREE_DIR"

HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
log() { echo "[$(date '+%H:%M:%S')] [router@${HOSTNAME}] $*"; }
debug() { [[ "$VERBOSE" == "true" ]] && log "[debug] $*" || true; }

# Portable base64 (GNU wraps at 76 chars by default, corrupting HTTP headers).
# Defined early because the pluggable ADO auth helper and early status-check both use it.
b64_encode() { base64 | tr -d '\n'; }

# Pluggable ADO auth (PAT / Entra SP / Entra WI) — sourced early so get_ado_auth_header*
# is available to every API call below, including the early non-active-PR status check.
# Replaces the previously-inlined hardcoded `Authorization: Basic :$ADO_PAT` headers.
if [ -f "$SCRIPT_DIR/../shared/ado_auth.sh" ]; then
  # shellcheck source=../shared/ado_auth.sh
  source "$SCRIPT_DIR/../shared/ado_auth.sh"
fi
# Resolve the ADO Authorization header once per call site via this wrapper; falls back
# to a PAT Basic header if the shared helper is unavailable (keeps the bot self-contained).
_ado_auth() { get_ado_auth_header_cached 2>/dev/null || echo "Basic $(echo -n ":${ADO_PAT:-}" | b64_encode)"; }

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
  case "${1:-MEDIUM}" in
    SMALL)  echo 400 ;;
    MEDIUM) echo 600 ;;
    LARGE)  echo 900 ;;
    *)      echo 600 ;;
  esac
}

# Global error trap — catch silent exits from set -e and log what failed
error_trap() {
  local exit_code=$?
  local line_no=$1
  if [ "$exit_code" -ne 0 ]; then
    log "❌ ERROR: Script failed at line $line_no with exit code $exit_code"
    log "❌ Command: $(sed -n "${line_no}p" "$0" 2>/dev/null || echo 'unknown')"
  fi
}
# Single definition for arming/re-arming the ERR trap — used at init and after
# the best-effort `set +e` block so the two sites cannot diverge.
arm_err_trap()   { trap 'error_trap $LINENO' ERR; }
disarm_err_trap() { trap - ERR; }
arm_err_trap

PAYLOAD="$1"
log "📥 Router started (PID: $$) with payload (${#PAYLOAD} bytes)"

# Validate payload is parseable JSON before attempting field extraction
if ! echo "$PAYLOAD" | jq empty 2>/dev/null; then
  log "❌ Payload is not valid JSON, skipping (handler PID: $$)"
  log "❌ Raw payload (first 500 chars): $(echo "$PAYLOAD" | head -c 500)"
  log "❌ Raw payload (hex, first 100 bytes): $(echo "$PAYLOAD" | xxd -l 100 -p 2>/dev/null || echo 'xxd unavailable')"
  exit 0
fi

# Event type routing — only handle PR comment events
EVENT_TYPE=$(echo "$PAYLOAD" | jq -r '.eventType // empty')
case "$EVENT_TYPE" in
  ms.vss-code.git-pullrequest-comment-event)
    ;; # Continue — this is what we handle
  "")
    log "⚠️  No eventType in payload, attempting to process as PR comment"
    ;;
  *)
    log "⏭️  Unhandled event type: $EVENT_TYPE, skipping"
    exit 0
    ;;
esac

# Defense-in-depth against the lease-comment self-trigger loop (start.sh filters this
# at intake; this guards the deferred-queue replay path which re-injects raw payloads
# that bypass intake). When a router PATCHes its own lease/status comment, ADO emits a
# comment-edit event with our machine marker in .resource.comment.content. Acting on it
# would just re-stamp the lease and emit another event — a tight CPU loop. These markers
# are bot-internal; a human comment never carries them, so bail without dispatching work.
_ROUTER_COMMENT_CONTENT=$(echo "$PAYLOAD" | jq -r '.resource.comment.content // empty' 2>/dev/null) || true
case "$_ROUTER_COMMENT_CONTENT" in
  *pr-bot-lease*|*pr-bot-status*)
    log "⏭️  Skipping self-authored bot lease/status comment edit (no-op event, prevents self-trigger loop)"
    exit 0
    ;;
esac

# Log payload structure for debugging (keys only, not values which may contain secrets)
log "📥 Payload keys: $(echo "$PAYLOAD" | jq -r 'keys | join(", ")' 2>/dev/null || echo 'unknown')"
log "📥 Payload size: ${#PAYLOAD} bytes"

# If the payload is suspiciously small, it's likely not a full ADO webhook — log and bail
if [ "${#PAYLOAD}" -lt 100 ]; then
  log "⚠️  Payload too small to be a valid ADO webhook (${#PAYLOAD} bytes), skipping"
  log "⚠️  Payload keys: $(echo "$PAYLOAD" | jq -r 'keys | join(", ")' 2>/dev/null || echo '[not JSON]')"
  exit 0
fi

# Parse ADO webhook payload
# ADO "Pull request commented on" webhook structure:
#   .resource.pullRequest.pullRequestId
#   .resource.pullRequest.repository.id
#   .resource.pullRequest.repository.name
#   .resource.pullRequest.sourceRefName
#   .resource.comment.id
#   .resource.comment.content
NOTIFICATION_ID=$(echo "$PAYLOAD" | jq -r '.notificationId // empty' 2>/dev/null) || true
PR_ID=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.pullRequestId // empty' 2>/dev/null) || true

# Deduplicate by ADO notificationId (survives ntfy replay storms)
# Lockless check — worst case two processes both proceed, but per-PR lock + ADO lease catches them downstream
if [ -n "$NOTIFICATION_ID" ]; then
  SEEN_NOTIFICATIONS_FILE="$STATE_DIR/seen-notifications.log"
  if grep -qxF "$NOTIFICATION_ID" "$SEEN_NOTIFICATIONS_FILE" 2>/dev/null; then
    log "⏭️  Skipping duplicate ADO notification: $NOTIFICATION_ID"
    exit 0
  fi
  echo "$NOTIFICATION_ID" >> "$SEEN_NOTIFICATIONS_FILE"
  # Prune to last 1000 entries periodically
  if [ "$(wc -l < "$SEEN_NOTIFICATIONS_FILE" 2>/dev/null || echo 0)" -gt 1200 ]; then
    tail -1000 "$SEEN_NOTIFICATIONS_FILE" > "${SEEN_NOTIFICATIONS_FILE}.tmp" && mv "${SEEN_NOTIFICATIONS_FILE}.tmp" "$SEEN_NOTIFICATIONS_FILE"
  fi
fi
REPO_ID=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.repository.id // empty' 2>/dev/null) || true
REPO_NAME=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.repository.name // empty' 2>/dev/null) || true
SOURCE_BRANCH=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.sourceRefName // empty' 2>/dev/null | sed 's|refs/heads/||') || true
COMMENT_ID=$(echo "$PAYLOAD" | jq -r '.resource.comment.id // empty' 2>/dev/null) || true

# Capture the PR head commit early (before any crash point) so the circuit
# breaker can key its per-commit failure streak even if the router crashes
# downstream. Falls back to the PR_DETAILS API fetch (done later) if absent;
# if still empty the breaker is skipped (never key on "").
HEAD_COMMIT=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.lastMergeSourceCommit.commitId // empty' 2>/dev/null) || true

if [ -z "$PR_ID" ]; then
  log "⚠️  Could not extract pullRequestId from payload, skipping"
  log "⚠️  Payload structure: $(echo "$PAYLOAD" | jq -r 'keys | join(", ")' 2>/dev/null || echo 'unparseable')"
  exit 0
fi

log "📋 Processing PR #${PR_ID} (repo: ${REPO_NAME}, branch: ${SOURCE_BRANCH})"

# Detect a deliberate bracket directive (e.g. [no-bot]) in free text WITHOUT
# false-matching prose or documentation that merely *mentions* the marker. A bare
# substring grep (the pattern [no-auto] still uses) fires on a PR whose title or
# body documents the marker — e.g. this very PR's title "…— [no-bot] stand-down…"
# or a backticked `[no-bot]` in a design doc — which would make the bot stand down
# on the wrong PRs. We treat the marker as a directive only when it stands at the
# START of a line (allowing leading spaces and a single list/quote bullet) and is
# NOT wrapped in backticks, i.e. an intentional `[marker]` on its own, not buried
# mid-sentence. Usage: pr_text_has_directive "<text>" "no-bot" ; rc 0 = present.
pr_text_has_directive() {
  local _text="$1" _marker="$2"
  printf '%s' "$_text" | grep -qiE "^[[:space:]]*([-*>][[:space:]]+)?\[${_marker}\]([[:space:]]|[:.]|\$)"
}

# --- Concurrency stand-down (EARLIEST possible — before lock/lease/worktree) ---
# When a human or an interactive agent is actively driving a PR's branch, the bot
# must NOT fetch/rebase/lease/push or create a worktree against it, or the two will
# race on the shared remote ref (the bot's force-push/reset-hard can clobber a
# concurrent push). Two opt-out signals, checked here with ZERO side effects:
#
#   Tier 1 — `[no-bot]` as a directive line in the PR title/description: full
#            hands-off. The bot stands down entirely (symmetric with the existing
#            `[no-auto]`, which only gates approve/complete). Matched via
#            pr_text_has_directive so a PR that merely *documents* the marker in
#            prose is NOT affected. The authoritative re-check happens later once
#            PR_DETAILS is fetched (some comment webhooks omit title in the payload),
#            and pr_heartbeat.sh skips these PRs so they are never re-dispatched.
#   Tier 2 — a `*-wip` source branch: a human WIP scratch ref. The bot skips it so an
#            interactive agent can stage work on `<branch>-wip` and fast-forward into
#            the real PR ref when ready, without the bot fighting over the scratch ref.
#
# Both bail with exit 0 (clean, no crash marker, no circuit penalty, no lease).
PR_BOT_WIP_SUFFIX="${PR_BOT_WIP_SUFFIX:--wip}"
if [ -n "$PR_BOT_WIP_SUFFIX" ] && [ -n "$SOURCE_BRANCH" ] && \
   [ "$SOURCE_BRANCH" != "${SOURCE_BRANCH%"$PR_BOT_WIP_SUFFIX"}" ]; then
  log "🤝 PR #${PR_ID} on WIP branch '${SOURCE_BRANCH}' (suffix '${PR_BOT_WIP_SUFFIX}') — standing down, human driving"
  exit 0
fi
# Best-effort early [no-bot] from the webhook payload (title/description may be absent
# on some comment events — the authoritative PR_DETAILS-based check is the safety net).
PAYLOAD_PR_TITLE=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.title // ""' 2>/dev/null) || true
PAYLOAD_PR_DESC=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.description // ""' 2>/dev/null) || true
if pr_text_has_directive "$(printf '%s\n%s' "$PAYLOAD_PR_TITLE" "$PAYLOAD_PR_DESC")" "no-bot"; then
  log "🤝 PR #${PR_ID} tagged [no-bot] — standing down (human driving), no lease/worktree/push"
  exit 0
fi

# --- [no-auto] opt-out (distinct from [no-bot]; does NOT stand the bot down) ---
# [no-auto] keeps comment-fixing, rebasing, conflict resolution and work-item
# linkage fully active; it ONLY disables auto-approve + auto-complete in the final
# policy gate (a human must approve & complete). Deliberately matched with a LENIENT
# bare substring grep (not the strict pr_text_has_directive used by [no-bot]):
#   * low consequence if it over-fires — the bot still does all its work; a human
#     just has to click merge — so the strict line-anchored matcher isn't needed;
#   * it MUST match combined tags like the spec convention "[SPEC][no-auto] <Title>"
#     (SUBMIT-RUNBOOK.md), which the line-anchored [no-bot] matcher would reject.
# (Asymmetry is intentional: standing the bot DOWN on a wrong PR is far worse than
# merely leaving a low-risk PR for a human to merge.) The authoritative recheck
# below refines SKIP_AUTO when the payload lacked title/body. SKIP_AUTO is consumed
# only at run_policy_gate, so this is otherwise inert.
SKIP_AUTO=0
if printf '%s\n%s' "$PAYLOAD_PR_TITLE" "$PAYLOAD_PR_DESC" | grep -qiE '\[no-auto\]'; then
  SKIP_AUTO=1
  log "⏸️  PR #${PR_ID} tagged [no-auto] — auto-approve/complete disabled (bot still fixes/rebases)"
fi

# --- Early bail for non-active PRs (before lease/threads/builds) ---
# Check the webhook payload first (zero API calls)
PAYLOAD_PR_STATUS=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.status // empty' 2>/dev/null) || true
if [ "$PAYLOAD_PR_STATUS" = "completed" ] || [ "$PAYLOAD_PR_STATUS" = "abandoned" ]; then
  log "⏭️  PR #${PR_ID} is not active (status: ${PAYLOAD_PR_STATUS} from payload), skipping early"
  exit 0
fi
# If payload didn't have status, do a lightweight API check
if [ -z "$PAYLOAD_PR_STATUS" ] && [ -n "$REPO_ID" ]; then
  PR_STATUS_CHECK=$(curl -s --max-time 10 \
    -H "Authorization: $(_ado_auth)" \
    "https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/git/repositories/${REPO_ID}/pullRequests/${PR_ID}?\$select=status&api-version=7.1" 2>/dev/null) || true
  if [ -n "$PR_STATUS_CHECK" ]; then
    EARLY_STATUS=$(echo "$PR_STATUS_CHECK" | jq -r '.status // empty' 2>/dev/null)
    # Match known non-active statuses (completed/abandoned/2/3) rather than assuming active=1
    if [ "$EARLY_STATUS" = "completed" ] || [ "$EARLY_STATUS" = "abandoned" ] || [ "$EARLY_STATUS" = "2" ] || [ "$EARLY_STATUS" = "3" ]; then
      log "⏭️  PR #${PR_ID} is not active (status: ${EARLY_STATUS}), skipping early"
      exit 0
    fi
  fi
fi

# --- Per-PR execution lock (EARLY) ---
# Acquired IMMEDIATELY after PR_ID is known, BEFORE any ADO API calls or worktree
# creation. This is the primary gate against concurrent processing of the same PR
# when multiple webhook notifications arrive within seconds of each other.
# Each notification has a unique notificationId, so notification dedup doesn't help —
# we need per-PR locking to ensure only one router process does the expensive work.
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1800}"
# Resolve the TARGET repository the bot operates on (creates worktrees in, fetches,
# pushes). Decoupled from where the harness scripts live so the harness can run from
# its own checkout while servicing a different repo. Precedence:
#   1. TARGET_REPO_DIR (explicit config) — the supported production setting.
#   2. Fallback: git toplevel of the CWD — preserves legacy behavior when the harness
#      lived inside the same repo it serviced.
if [ -n "${TARGET_REPO_DIR:-}" ]; then
  REPO_ROOT=$(git -C "$TARGET_REPO_DIR" rev-parse --show-toplevel 2>/dev/null)
else
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT/.git" ]; then
  log "❌ Cannot determine git repo root (REPO_ROOT='${REPO_ROOT:-}', TARGET_REPO_DIR='${TARGET_REPO_DIR:-}', CWD=$(pwd))"
  log "❌ Set TARGET_REPO_DIR in config.env to an absolute path of a local clone of the repo to service"
  exit 1
fi

# Verify git can authenticate to remote (catches missing credential helper in systemd/launchd)
if ! git -C "$REPO_ROOT" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
  # One-shot self-heal: the monorepo origin may still be SSH while this daemon runs with
  # no usable SSH agent (the common cause of exit 128 here). When an ADO_PAT is available,
  # convert origin → HTTPS and wire the PAT credential helper, then retry ONCE. The
  # converter + its credential helper are snapshotted next to this script by start.sh, so
  # $SCRIPT_DIR resolves them even though the router runs from the ephemeral snapshot.
  HEALED=false
  if [ -n "${ADO_PAT:-}" ] && [ -f "$SCRIPT_DIR/setup-git-credentials.sh" ]; then
    log "🔧 git ls-remote failed — attempting SSH→HTTPS+PAT self-heal for origin..."
    # shellcheck source=../setup-git-credentials.sh
    source "$SCRIPT_DIR/setup-git-credentials.sh"
    # Capture (don't pipe) the converter's output so `set -o pipefail` can't trip on a
    # non-zero error count, then mirror each line into the journal for visibility.
    HEAL_OUTPUT=$(setup_git_credentials "$REPO_ROOT" 2>&1) || true
    while IFS= read -r _hl; do [ -n "$_hl" ] && log "    $_hl"; done <<< "$HEAL_OUTPUT"
    if git -C "$REPO_ROOT" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
      log "✅ Self-heal succeeded — origin reachable over HTTPS+PAT"
      HEALED=true
    fi
  fi
  if [ "$HEALED" != true ]; then
    log "❌ git ls-remote failed — cannot reach origin"
    log "❌ Run: ./install-service.sh  (auto-configures HTTPS + credential helper)"
    log "❌ Or:  source '$SCRIPT_DIR/setup-git-credentials.sh' && setup_git_credentials '$REPO_ROOT'"
    exit 1
  fi
fi
PR_LOCK_DIR="$STATE_DIR/pr-${PR_ID}.lock"
# A fresh lock dir whose PID line is still empty is a router mid-acquisition, NOT a
# dead holder — the holder writes its PID immediately after mkdir. Any lock younger
# than this window with no live PID is treated as "being acquired" (yield), closing
# the TOCTOU that let two routers co-acquire one PR (see the acquire block below).
LOCK_ACQUIRE_WINDOW_SECS="${LOCK_ACQUIRE_WINDOW_SECS:-10}"
# Validate: must be a positive integer in [2, 30]. A value of 0 makes the
# mid-acquire elif unreachable (re-exposing the TOCTOU); a non-numeric value
# causes [ -lt ] to error. Clamp to the default on any invalid input.
case "$LOCK_ACQUIRE_WINDOW_SECS" in
  ''|*[!0-9]*) LOCK_ACQUIRE_WINDOW_SECS=10 ;;
esac
[ "$LOCK_ACQUIRE_WINDOW_SECS" -lt 2 ] 2>/dev/null && LOCK_ACQUIRE_WINDOW_SECS=2
[ "$LOCK_ACQUIRE_WINDOW_SECS" -gt 30 ] 2>/dev/null && LOCK_ACQUIRE_WINDOW_SECS=30

cleanup() {
  local exit_status=$?  # Capture the REAL exit code FIRST — `set +e` is a builtin
                        # that would reset $? to 0 (the cause of the silent #1340
                        # loop: crash markers/breaker never saw the true code).
  set +e  # Never let cleanup fail partway through
  # Write lastexit BEFORE removing inflight breadcrumb (Change 3 + Thread 11785).
  # An uncatchable SIGKILL between these two ops should leave BOTH artifacts (the
  # safe direction: reap_jobs sees the inflight breadcrumb + a valid lastexit, giving
  # it strictly MORE information). The old order (rm inflight first, then write
  # lastexit) had a gap where a SIGKILL would leave NEITHER: reap_jobs would see
  # true_rc=0 from `( router || true )` and take the success path — the silent-drop
  # bug. Writing lastexit first closes that window.
  if [ -n "${PR_ID:-}" ]; then
    echo "$exit_status" > "$STATE_DIR/pr-${PR_ID}.lastexit" 2>/dev/null || true
  fi
  # NOW remove the in-flight breadcrumb — its absence tells start.sh "cleanup ran".
  [ -n "${PR_ID:-}" ] && rm -f "$STATE_DIR/pr-${PR_ID}.inflight" 2>/dev/null
  # Circuit-breaker outcome — ONLY when we actually held the lease and did work
  # (LEASE_COMMENT_ID set). Pre-lease exits (circuit-open skip, non-active PR,
  # duplicate, lost race) must NOT touch breaker state, so the breaker self-expires
  # via nextRetryEpoch and stays the sole retry governor. Best-effort; never fail.
  # Exit 75 (YIELD) is contention, NOT a defect — it must NOT record a circuit
  # failure (that would back off a perfectly healthy PR just because a human was
  # mid-push). It is handled in the dedicated yield block below.
  if [ -n "${LEASE_COMMENT_ID:-}" ] && [ -n "${PR_ID:-}" ] && [ -n "${HEAD_COMMIT:-}" ] && [ "$exit_status" -ne 75 ]; then
    if [ "$exit_status" -eq 0 ]; then
      circuit_record_success "$PR_ID" "$HEAD_COMMIT" 2>/dev/null || true
    else
      circuit_record_failure "$PR_ID" "$HEAD_COMMIT" "$exit_status" 2>/dev/null || true
    fi
  fi
  # Release distributed lease (best-effort)
  if [ -n "${LEASE_THREAD_ID:-}" ]; then
    if [ "$exit_status" -eq 0 ]; then
      release_pr_lease "done" "pushed fixes"
    elif [ "$exit_status" -eq 75 ]; then
      # YIELD: release as "done" so the lease filter treats it as NON-active. This
      # release IS the re-dispatch mechanism — pr_heartbeat.sh sees no active lease +
      # still-actionable work (the unresolved comments/failing build we couldn't push
      # a fix for) and re-dispatches on its next cycle (~5min), rebuilding a FRESH
      # payload from the current PR list. We deliberately do NOT drop a deferred
      # requeue here: that drains every ~60s and would re-invoke Claude (expensive)
      # far tighter than the intended ~5min yield backoff. "done" (not "failed")
      # also avoids a scary visible ⚠️ comment for what is benign branch contention.
      release_pr_lease "done" "yielded (branch contended) — will retry"
    else
      release_pr_lease "failed" "exit code $exit_status"
    fi
  fi
  # Write crash marker for recovery on restart. Exit 75 (yield) is NOT a crash —
  # it self-recovers via the heartbeat (lease released non-active above), so it
  # gets no marker and no circuit penalty.
  if [ "$exit_status" -ne 0 ] && [ "$exit_status" -ne 75 ] && [ -n "${PR_ID:-}" ]; then
    log "💥 PR #${PR_ID} handler crashed (exit code $exit_status)"
    jq -n --arg pr "${PR_ID}" --arg code "$exit_status" \
         --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
         --arg host "$(hostname -s 2>/dev/null || echo unknown)" \
         --arg repo "${REPO_ID:-}" \
         --arg lease_thread "${LEASE_THREAD_ID:-}" \
         --arg lease_comment "${LEASE_COMMENT_ID:-}" \
         --argjson lease_expires "${LEASE_EXPIRES:-0}" \
         '{pr:$pr, exitCode:$code, timestamp:$ts, host:$host, repoId:$repo,
           leaseThreadId:$lease_thread, leaseCommentId:$lease_comment,
           leaseExpires:($lease_expires|tonumber)}' \
      > "$STATE_DIR/pr-${PR_ID}.crashed" 2>/dev/null || true
  fi
  # Clean up worktree when done (branch persists in the repo).
  # $WORK_DIR is keyed on PR id AND this router's PID ($WORKTREE_DIR/pr-<ID>-<PID>),
  # so it is unique to THIS run — no sibling router can be inside it, and our rm -rf
  # can only ever delete our own directory. (Pre-PID, the path was shared per-PR and
  # a sibling's cleanup could yank the dir out from under a live router → exit 128.)
  if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
    log "🧹 Removing worktree for PR #${PR_ID} (normal exit cleanup)..."
    git -C "$REPO_ROOT" worktree remove --force "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  fi
  # Release per-PR execution lock
  rm -f "$STATE_DIR/pr-${PR_ID}.lock/pid" 2>/dev/null
  rmdir "$STATE_DIR/pr-${PR_ID}.lock" 2>/dev/null || true
}
trap cleanup EXIT
# In-flight breadcrumb: created the instant the EXIT trap is armed, removed by
# cleanup() on ANY catchable exit. If it SURVIVES after the router process ends, the
# router was hard-killed by an uncatchable signal (macOS jetsam SIGKILL / OOM /
# _kill_subtree) and cleanup() never ran. start.sh's reap_jobs reads this to tell a
# real "✅ success" from a SIGKILL that the ( router || true ) wrapper masks as rc 0.
# It is created HERE — AFTER every pre-trap early-bail (unhandled event, duplicate
# notification, [no-bot], *-wip, inactive PR, self-edit) has already exited 0 — so
# those legitimate skips never leave a breadcrumb and are never misread as crashes.
INFLIGHT_FILE="$STATE_DIR/pr-${PR_ID}.inflight"
: > "$INFLIGHT_FILE" 2>/dev/null || true

if ! mkdir "$PR_LOCK_DIR" 2>/dev/null; then
  # Lock exists — check if the holding process is still alive before declaring stale
  _pr_lock_ts=$(head -1 "$PR_LOCK_DIR/pid" 2>/dev/null || echo 0)
  _pr_lock_pid=$(sed -n '2p' "$PR_LOCK_DIR/pid" 2>/dev/null || echo 0)
  _pr_lock_lstart=$(sed -n '3p' "$PR_LOCK_DIR/pid" 2>/dev/null || echo "")
  _pr_lock_age=$(( $(date +%s) - _pr_lock_ts ))

  if [ "$_pr_lock_pid" -gt 0 ] 2>/dev/null && kill -0 "$_pr_lock_pid" 2>/dev/null; then
    # PID alive — check lstart for PID reuse, consistent with pr_lease.sh pattern.
    # If lstart was recorded and differs from current, the PID was recycled → reclaim.
    # If no lstart recorded (old lock file format), safe direction: treat as held.
    if [ -n "$_pr_lock_lstart" ]; then
      _pr_current_lstart=$(ps -o lstart= -p "$_pr_lock_pid" 2>/dev/null | xargs) || _pr_current_lstart=""
      if [ -n "$_pr_current_lstart" ] && [ "$_pr_lock_lstart" != "$_pr_current_lstart" ]; then
        log "🧹 Reclaiming PR lock for #${PR_ID} (PID $_pr_lock_pid recycled: lstart='${_pr_current_lstart}' != recorded='${_pr_lock_lstart}')"
        rm -f "$PR_LOCK_DIR/pid" 2>/dev/null
        rmdir "$PR_LOCK_DIR" 2>/dev/null || true
        mkdir "$PR_LOCK_DIR" 2>/dev/null || { log "⏭️  PR #${PR_ID} lock race — another process won, skipping"; exit 0; }
      else
        log "⏭️  PR #${PR_ID} is being processed by PID $_pr_lock_pid (lock age: ${_pr_lock_age}s), skipping"
        exit 0
      fi
    else
      log "⏭️  PR #${PR_ID} is being processed by PID $_pr_lock_pid (lock age: ${_pr_lock_age}s), skipping"
      exit 0
    fi
  elif [ "${_pr_lock_pid:-0}" -le 0 ] 2>/dev/null && [ "$_pr_lock_age" -lt "$LOCK_ACQUIRE_WINDOW_SECS" ]; then
    # Lock dir exists but the PID line is empty/0 AND the dir is brand-new: the holder
    # writes its PID immediately after mkdir (no slow ops between), so a missing PID on
    # a fresh dir means a concurrent router is inside the sub-second acquisition window —
    # NOT a dead holder. Treating it as dead (the old `else`) was the TOCTOU that let two
    # routers both "acquire" the same PR lock (PR #1420: every log line duplicated, both
    # iteration:0), then race + destroy a shared worktree → exit 128. Yield to the winner.
    log "⏭️  PR #${PR_ID} lock dir is mid-acquire by another router (no PID yet, age ${_pr_lock_age}s), skipping"
    exit 0
  else
    # PID is gone (dead holder). Reclaim the lock IMMEDIATELY rather than waiting out
    # an age timer. Liveness (kill -0), not age, is the correct signal.
    log "🧹 Reclaiming dead-holder PR lock for #${PR_ID} (PID $_pr_lock_pid exited, age: ${_pr_lock_age}s)"
    rm -f "$PR_LOCK_DIR/pid" 2>/dev/null
    rmdir "$PR_LOCK_DIR" 2>/dev/null || true
    mkdir "$PR_LOCK_DIR" 2>/dev/null || { log "⏭️  PR #${PR_ID} lock race — another process won, skipping"; exit 0; }
  fi
fi
# Write timestamp, PID, AND lstart into lock file for liveness + PID-reuse detection
_pr_self_lstart=$(ps -o lstart= -p $$ 2>/dev/null | xargs) || _pr_self_lstart=""
printf '%s\n%s\n%s\n' "$(date +%s)" "$$" "$_pr_self_lstart" > "$PR_LOCK_DIR/pid"
debug "🔒 Acquired PR lock for #${PR_ID} (PID: $$)"

# --- Branch resolution: ensure branch is available locally ---
# First check local branches/worktrees (fast path for branches we created).
# If not found locally, fetch from remote — this allows processing Renovate PRs
# and PRs created by other tools. The lease system prevents duplicate work
# across machines; local branch affinity is just an optimization, not a gate.
LOCAL_MATCH=false

# Check local branches (includes branches created by this machine)
if git -C "$REPO_ROOT" branch --list "$SOURCE_BRANCH" | grep -q .; then
  LOCAL_MATCH=true
fi

# Check worktrees (bot's own worktrees for this PR)
if [ "$LOCAL_MATCH" = false ] && git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | grep -q "branch refs/heads/$SOURCE_BRANCH"; then
  LOCAL_MATCH=true
fi

# Not found locally — try to fetch from remote and create local tracking branch
if [ "$LOCAL_MATCH" = false ]; then
  log "🌐 Branch '${SOURCE_BRANCH}' not found locally, fetching from remote..."
  local_fetch_err=$(git -C "$REPO_ROOT" fetch origin "$SOURCE_BRANCH" 2>&1) || {
    log "⏭️  Failed to fetch '${SOURCE_BRANCH}' from remote: $local_fetch_err"
    exit 0
  }
  # Use -f to force-update if a stale local branch already exists
  local_branch_err=$(git -C "$REPO_ROOT" branch -f "$SOURCE_BRANCH" "origin/$SOURCE_BRANCH" 2>&1) || {
    log "⏭️  Failed to create local branch '${SOURCE_BRANCH}': $local_branch_err"
    exit 0
  }
  LOCAL_MATCH=true
  log "✅ Fetched and created local branch '${SOURCE_BRANCH}'"
fi
log "✅ Branch '${SOURCE_BRANCH}' available, processing"

# State management
STATE_FILE="$STATE_DIR/pr-${PR_ID}.json"
if [ -f "$STATE_FILE" ]; then
  LAST_COMMIT=$(jq -r '.lastProcessedCommit // ""' "$STATE_FILE")
else
  LAST_COMMIT=""
  echo '{}' > "$STATE_FILE"
fi

# Dedup: ntfy notification dedup + lease system handles concurrent processing.
# Comment-ID-based dedup removed — ADO comment IDs are per-thread (not global),
# so comparing across threads incorrectly skips new comments on different threads.

# ADO API call with exponential backoff retry and full error logging.
# Usage: ado_api_call <url> [method] [body]
# Outputs response body on success, returns non-zero on failure.
ado_api_call() {
  local url="$1"
  local method="${2:-GET}"
  local body="${3:-}"
  local content_type="${4:-application/json}"
  local max_retries=3
  local retry_delay=2
  local attempt=0
  local tmpfile hdrfile
  tmpfile=$(mktemp)
  hdrfile=$(mktemp)

  while [ "$attempt" -le "$max_retries" ]; do
    local http_code
    if [ -n "$body" ]; then
      http_code=$(curl -s -o "$tmpfile" -D "$hdrfile" -w '%{http_code}' \
        -X "$method" \
        -H @<(echo "Authorization: $(_ado_auth)") \
        -H "Content-Type: ${content_type}" \
        -d "$body" \
        --max-time 30 \
        "$url" 2>/dev/null) || http_code="000"
    else
      http_code=$(curl -s -o "$tmpfile" -D "$hdrfile" -w '%{http_code}' \
        -H @<(echo "Authorization: $(_ado_auth)") \
        --max-time 30 \
        "$url" 2>/dev/null) || http_code="000"
    fi

    # Auth failures — not transient, bail immediately
    if [[ "$http_code" =~ ^(302|401|403)$ ]] || grep -q '<html>' "$tmpfile" 2>/dev/null; then
      log "❌ ADO API auth failure (HTTP $http_code) — check ADO_PAT validity"
      log "❌ URL: $url"
      log "❌ Full response:"
      cat "$tmpfile" >&2
      rm -f "$tmpfile" "$hdrfile"
      return 1
    fi

    # Success — strip UTF-8 BOM that some ADO API responses include
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      sed '1s/^\xEF\xBB\xBF//' "$tmpfile"
      rm -f "$tmpfile" "$hdrfile"
      return 0
    fi

    # Transient — retry with backoff (429 uses Retry-After header)
    if [ "$attempt" -lt "$max_retries" ]; then
      local sleep_duration="$retry_delay"
      if [ "$http_code" = "429" ]; then
        local ra
        ra=$(grep -i '^retry-after:' "$hdrfile" 2>/dev/null | head -1 | tr -d '\r' | awk '{print $2}')
        # Validate it's a positive integer (Retry-After can also be an HTTP-date)
        if [[ "$ra" =~ ^[0-9]+$ ]] && [ "$ra" -gt 0 ]; then
          # Cap at 120s
          [ "$ra" -gt 120 ] && ra=120
          sleep_duration="$ra"
          log "⚠️  ADO API HTTP 429 (attempt $((attempt+1))/$max_retries), Retry-After: ${sleep_duration}s"
        else
          log "⚠️  ADO API HTTP 429 (attempt $((attempt+1))/$max_retries), no Retry-After header, backing off ${sleep_duration}s"
        fi
      else
        log "⚠️  ADO API HTTP $http_code (attempt $((attempt+1))/$max_retries), retrying in ${sleep_duration}s..."
      fi
      log "⚠️  URL: $url"
      log "⚠️  Response: $(cat "$tmpfile")"
      sleep "$sleep_duration"
      retry_delay=$((retry_delay * 2))
    else
      log "❌ ADO API failed after $((max_retries+1)) attempts (HTTP $http_code)"
      log "❌ URL: $url"
      log "❌ Full response:"
      cat "$tmpfile" >&2
      rm -f "$tmpfile" "$hdrfile"
      return 1
    fi
    attempt=$((attempt + 1))
  done
  rm -f "$tmpfile" "$hdrfile"
  return 1
}

# Fetch unresolved PR threads from ADO REST API (for thread ID tracking + resolution)
ADO_BASE="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis"

# --- Distributed lease via ADO PR comment ---
# Source lease functions (requires ado_api_call, ADO_BASE, log — all defined above)
source "$SCRIPT_DIR/pr_lease.sh"
source "$SCRIPT_DIR/pr_policies.sh"
source "$SCRIPT_DIR/pr_analysis.sh"
source "$SCRIPT_DIR/pr_workitems.sh"
source "$SCRIPT_DIR/pr_circuit.sh"
source "$SCRIPT_DIR/pr_constants.sh"

# --- Circuit breaker gate (BEFORE lease acquisition) ---
# If this PR keeps crashing on the SAME head commit, skip it while its backoff
# window is open. Critical placement: LEASE_THREAD_ID/LEASE_COMMENT_ID are still
# empty here, so the EXIT trap writes NO failed lease and NO .crashed marker —
# the breaker (which self-expires via nextRetryEpoch) is the sole retry governor.
# A new commit (different SHA) resets the breaker → fresh code gets a fresh try.
# Fall back to PR_DETAILS API for the head commit if the webhook payload lacked it.
_bk_pr_details=""
if [ -z "${HEAD_COMMIT:-}" ] && [ -n "$REPO_ID" ]; then
  _bk_pr_details=$(ado_api_call "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}?api-version=7.1" 2>/dev/null) || true
  if [ -n "$_bk_pr_details" ]; then
    HEAD_COMMIT=$(echo "$_bk_pr_details" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null) || true
  fi
fi
if circuit_is_open "$PR_ID" "${HEAD_COMMIT:-}"; then
  if [ "$CIRCUIT_STATE" = "quarantined" ]; then
    log "🚦 Circuit QUARANTINED for #${PR_ID} on ${HEAD_COMMIT:0:8} (retry in ${CIRCUIT_RETRY_IN}s) — push a new commit to clear"
  else
    log "🚦 Circuit open for #${PR_ID} on ${HEAD_COMMIT:0:8} (retry in ${CIRCUIT_RETRY_IN}s)"
  fi
  exit 0
fi

# --- Authoritative [no-bot] recheck (safety net for comment webhooks) ---
# The EARLY payload check (top of file) can miss [no-bot] when a comment-event
# payload omits the PR title/description. Now — still BEFORE lease acquisition and
# worktree creation (the destructive ops: reset --hard / force-push) — confirm
# against the PR details API, but ONLY when the payload lacked both title and
# description (otherwise the early check already covered it). Reuse the circuit
# gate's fetch if it happened; else do one lightweight fetch. Bail clean: exit 0
# with no lease and no worktree; cleanup() only releases the cheap local lock
# (LEASE_*/HEAD-marker untouched), so there is no circuit penalty or .crashed.
if [ -z "${PAYLOAD_PR_TITLE:-}" ] && [ -z "${PAYLOAD_PR_DESC:-}" ]; then
  _nb_details="${_bk_pr_details:-}"
  if [ -z "$_nb_details" ] && [ -n "$REPO_ID" ]; then
    _nb_details=$(ado_api_call "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}?api-version=7.1" 2>/dev/null) || true
  fi
  if [ -n "$_nb_details" ]; then
    _nb_title=$(echo "$_nb_details" | jq -r '.title // ""' 2>/dev/null) || true
    _nb_desc=$(echo "$_nb_details" | jq -r '.description // ""' 2>/dev/null) || true
    if pr_text_has_directive "$(printf '%s\n%s' "$_nb_title" "$_nb_desc")" "no-bot"; then
      log "🤝 PR #${PR_ID} tagged [no-bot] (confirmed via PR details) — standing down, no lease/worktree/push"
      exit 0
    fi
    # Same authoritative source refines [no-auto] (payload lacked title/body above).
    # Lenient substring match, mirroring the early check (see rationale there).
    if [ "${SKIP_AUTO:-0}" != "1" ] && printf '%s\n%s' "$_nb_title" "$_nb_desc" | grep -qiE '\[no-auto\]'; then
      SKIP_AUTO=1
      log "⏸️  PR #${PR_ID} tagged [no-auto] (confirmed via PR details) — auto-approve/complete disabled"
    fi
  fi
fi

# PR_THREADS_JSON is set by check_pr_lease for downstream reuse
PR_THREADS_JSON=""
if check_pr_lease "$PR_ID" "$REPO_ID"; then
  log "⏭️  PR #${PR_ID} has active lease on ${EXISTING_LEASE_HOST}, skipping"
  # Foreign-lease cooldown stamp (zero API). When ANOTHER host holds the lease,
  # ADO keeps emitting genuine PR events for that PR (the foreign bot's pushes,
  # build-status updates, etc.) — each a DISTINCT notificationId, so neither the
  # dedup log nor the self-edit content filter catches them. Before this stamp,
  # every such event spawned a full router that paid two ADO calls only to
  # rediscover the foreign lease and exit 0 (observed: PR #1404 — 7 routers in
  # 14s while another host drove it). We already KNOW the lease is foreign here, for
  # free, so record it: start.sh's intake coalesces subsequent events for this PR
  # until the stamp expires, with no extra API calls. Scoped to FOREIGN holders
  # only — never our own host — so any self-reclaim path is unaffected. The stamp
  # is advisory/best-effort: the heartbeat re-dispatch path deliberately does NOT
  # consult it, so authoritative recovery still rebuilds from the live PR list.
  if [ "${EXISTING_LEASE_HOST}" != "${HOSTNAME}" ] && [ -n "${EXISTING_LEASE_HOST}" ] \
     && [ "${EXISTING_LEASE_HOST#unknown}" = "${EXISTING_LEASE_HOST}" ]; then
    _fl_cooldown="${PR_BOT_FOREIGN_LEASE_COOLDOWN:-120}"
    # Guard against a non-numeric override (e.g. "2m"): without this the arithmetic
    # expansion below would fail silently (suppressed by 2>/dev/null), write no stamp,
    # and quietly disable coalescing with no diagnostic. Fall back to the 120s default.
    case "$_fl_cooldown" in ''|*[!0-9]*) _fl_cooldown=120 ;; esac
    if echo "$(( $(date +%s) + _fl_cooldown ))" > "$STATE_DIR/pr-${PR_ID}.foreign-lease" 2>/dev/null; then
      log "🧊 PR #${PR_ID} wrote foreign-lease cooldown stamp (${_fl_cooldown}s) — intake coalesces further events until it expires"
    fi
  fi
  exit 0
fi
if ! acquire_pr_lease "$PR_ID" "$REPO_ID"; then
  log "⏭️  PR #${PR_ID} lease acquisition failed (race or API error), skipping"
  exit 0
fi
LEASE_EXPIRES=$(($(date +%s) + ${CLAUDE_TIMEOUT:-1800}))

log "🔍 Fetching active PR threads..."
THREADS_URL="${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}/threads?api-version=7.1"
debug "URL: $THREADS_URL"
# Reuse threads JSON from lease check if available (avoids duplicate API call)
if [ -n "${PR_THREADS_JSON:-}" ]; then
  THREADS_JSON="$PR_THREADS_JSON"
  log "📡 Reusing threads from lease check"
else
  THREADS_JSON=$(ado_api_call "$THREADS_URL") || { log "❌ Failed to fetch threads, aborting"; exit 1; }
fi

# Validate we got a proper API response
if ! echo "$THREADS_JSON" | jq -e '.value' >/dev/null 2>&1; then
  log "❌ ADO API returned unexpected response (not a valid threads list)"
  log "❌ Full response:"
  echo "$THREADS_JSON" >&2
  exit 1
fi
log "📡 ADO API returned $(echo "$THREADS_JSON" | jq '.value | length') threads"

# Filter to active threads with unresolved comments (for dedup + thread resolution)
# Cap at MAX_THREADS to prevent context overflow that causes max_turns failures.
# Prioritize most recent threads (highest threadId = newest).
MAX_THREADS="${MAX_THREADS:-15}"
UNRESOLVED_COMMENTS=$(echo "$THREADS_JSON" | jq -r --argjson max "$MAX_THREADS" '
  [.value[]?
   | select(.status == "active" or .status == null)
   | select(.properties.CodeReviewThreadType.["$value"] != "VoteUpdate")
   | {
       threadId: .id,
       status: .status,
       comments: [.comments[]
         | select(.commentType != "system")
         | {id: .id}
       ]
     }
   | select(.comments | length > 0)
  ] | sort_by(-.threadId) | .[:$max]' 2>/dev/null)

TOTAL_UNRESOLVED=$(echo "$THREADS_JSON" | jq '[.value[]? | select(.status == "active" or .status == null) | select(.properties.CodeReviewThreadType.["$value"] != "VoteUpdate") | select([.comments[] | select(.commentType != "system")] | length > 0)] | length' 2>/dev/null || echo "0")
COMMENT_COUNT=$(echo "$UNRESOLVED_COMMENTS" | jq 'length' 2>/dev/null || echo "0")
THREADS_CAPPED=false
if [ "$TOTAL_UNRESOLVED" -gt "$MAX_THREADS" ]; then
  THREADS_CAPPED=true
  log "📝 Capped threads: processing $MAX_THREADS of $TOTAL_UNRESOLVED unresolved threads (oldest deferred)"
fi

HAS_UNRESOLVED_COMMENTS=true
if [ "$COMMENT_COUNT" = "0" ]; then
  HAS_UNRESOLVED_COMMENTS=false
  log "✅ No new unresolved comments to process"
  # Don't exit yet — check build policies below. If builds are failing,
  # we should still invoke Claude to fix the build even without review comments.
fi

if [ "$HAS_UNRESOLVED_COMMENTS" = true ]; then
  log "📝 Found $COMMENT_COUNT threads with new comments"
fi

# Track thread IDs for later resolution
THREAD_IDS=$(echo "$UNRESOLVED_COMMENTS" | jq -r '[.[].threadId] | join(",")' 2>/dev/null || echo "")

# --- Early build policy check ---
# Check policies BEFORE worktree creation so we can skip work when
# there are no comments AND no failing builds.
BUILD_FAILURE_CONTEXT=""
PROJECT_ID=$(echo "$PAYLOAD" | jq -r '.resource.pullRequest.repository.project.id // empty' 2>/dev/null) || true
if [ -z "$PROJECT_ID" ]; then
  # Fetch from PR details API
  PR_DETAILS_URL="${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}?api-version=7.1"
  PR_DETAILS=$(ado_api_call "$PR_DETAILS_URL" 2>/dev/null) || true
  PROJECT_ID=$(echo "$PR_DETAILS" | jq -r '.repository.project.id // empty' 2>/dev/null)
fi
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID="$ADO_PROJECT"
fi
POLICY_EVAL_URL="${ADO_BASE}/policy/evaluations?artifactId=$(printf '%s' "vstfs:///CodeReview/CodeReviewId/${PROJECT_ID}/${PR_ID}" | jq -sRr @uri)&api-version=7.1-preview"
POLICY_EVALS=$(ado_api_call "$POLICY_EVAL_URL" 2>/dev/null) || true
HAS_FAILING_BUILD=false
# --- BEGIN best-effort build-failure enrichment (set +e bracket) ---
# This region only builds advisory build-failure context for the Claude prompt.
# It must NEVER be able to abort the router (a malformed ADO API response here
# caused the 2-day crash loop on PR #1340). Disable errexit for the whole block;
# re-enabled by the matching `set -e` after the closing `fi`. Do NOT delete either
# marker. Mirrors the in-function `set +e` pattern in cleanup().
#
# ALSO disarm the global ERR trap here: a bash ERR trap fires on a non-zero command
# REGARDLESS of `set +e` (errexit only controls whether the shell *exits* — the trap
# still runs). Without this, any tolerated failure in this best-effort block (e.g. jq
# exit 5 when an ADO API returns a non-JSON error page — observed on the test/runs
# endpoint) logs a SCARY false "❌ ERROR: Script failed at line N" even though the
# block correctly continues. Re-armed alongside the matching `set -e` below.
disarm_err_trap
set +e
if [ -n "$POLICY_EVALS" ]; then
  # Only the ADO "Build" policy type (0609b952-…) represents a build-validation gate.
  # Other blocking policies can also report status="rejected" — notably
  # "Require a merge strategy" (type fa4e907d-…), which is rejected simply because no
  # merge strategy has been selected yet (resolved at auto-complete time, NOT by any
  # code change). Selecting those as a "failing build" made the bot invoke Claude to
  # "fix the build" on an already-passing PR, never reaching auto-approve/-complete —
  # an infinite re-dispatch loop (observed on PR #1376). Gate on the Build policy type
  # id so non-build policies are ignored here and handled by the normal policy gate.
  FAILING_POLICIES=$(echo "$POLICY_EVALS" | jq -r --arg bpt "$BUILD_POLICY_TYPE_ID" '
    [.value[]? | select((.status == "rejected" or .status == "broken")
       and .configuration.type.id == $bpt)
     | {
         name: (.configuration.settings.displayName // .configuration.type.displayName // "unknown"),
         status: .status,
         buildId: (.context.buildId // null)
       }
    ]' 2>/dev/null || echo "[]")
  FAIL_COUNT=$(echo "$FAILING_POLICIES" | jq 'length' 2>/dev/null || echo "0")
  if [ "$FAIL_COUNT" -gt 0 ]; then
    HAS_FAILING_BUILD=true
    log "🏗️  Found $FAIL_COUNT failing build policies"
    # Fetch build logs for the first failing build
    FIRST_BUILD_ID=$(echo "$FAILING_POLICIES" | jq -r '.[0].buildId // empty' 2>/dev/null)
    BUILD_LOG_SNIPPET=""
    if [ -n "$FIRST_BUILD_ID" ]; then
      TIMELINE_URL="${ADO_BASE}/build/builds/${FIRST_BUILD_ID}/timeline?api-version=7.1"
      TIMELINE=$(ado_api_call "$TIMELINE_URL" 2>/dev/null) || true
      if [ -n "$TIMELINE" ]; then
        FAILED_LOG_ID=$(echo "$TIMELINE" | jq -r '
          [.records[]? | select(.result == "failed" and .log.id != null) | .log.id] | first // empty
        ' 2>/dev/null)
      fi
      if [ -n "${FAILED_LOG_ID:-}" ]; then
        LOG_CONTENT=$(ado_api_call "${ADO_BASE}/build/builds/${FIRST_BUILD_ID}/logs/${FAILED_LOG_ID}?api-version=7.1" 2>/dev/null) || true
        BUILD_LOG_SNIPPET=$(echo "$LOG_CONTENT" | tail -c 5000)
      else
        BUILD_LOGS_URL="${ADO_BASE}/build/builds/${FIRST_BUILD_ID}/logs?api-version=7.1"
        BUILD_LOGS=$(ado_api_call "$BUILD_LOGS_URL" 2>/dev/null) || true
        if [ -n "$BUILD_LOGS" ]; then
          LAST_LOG_ID=$(echo "$BUILD_LOGS" | jq -r '.value[-1].id // empty' 2>/dev/null)
          if [ -n "$LAST_LOG_ID" ]; then
            LOG_CONTENT=$(ado_api_call "${ADO_BASE}/build/builds/${FIRST_BUILD_ID}/logs/${LAST_LOG_ID}?api-version=7.1" 2>/dev/null) || true
            BUILD_LOG_SNIPPET=$(echo "$LOG_CONTENT" | tail -c 5000)
          fi
        fi
      fi
    fi

    # Fetch failed test results from the build's test runs
    TEST_FAILURE_CONTEXT=""
    if [ -n "$FIRST_BUILD_ID" ]; then
      # Get test runs for this build
      TEST_RUNS_URL="${ADO_BASE}/test/runs?buildId=${FIRST_BUILD_ID}&api-version=7.1-preview.6"
      TEST_RUNS=$(ado_api_call "$TEST_RUNS_URL" 2>/dev/null) || true
      # Validate it's parseable JSON AND extract the latest failing run ID in a
      # single jq invocation (avoids a redundant double-parse). Under load the ADO
      # test/runs endpoint can return a non-JSON error page (e.g. an HTML 500),
      # which makes jq exit 5 (#1340 fragility class). The set +e bracket already
      # stops that from aborting the router; skipping outright also avoids the
      # (now-disarmed) ERR-trap noise.
      if [ -n "$TEST_RUNS" ]; then
        LATEST_RUN_ID=$(echo "$TEST_RUNS" | jq -re '
          [.value[]? | select(.state == "Completed") | select((.totalTests // 0) > (.passedTests // 0))] | last | .id // empty
        ' 2>/dev/null) || LATEST_RUN_ID=""
        if [ -n "$LATEST_RUN_ID" ]; then
          # Fetch failed test results
          TEST_RESULTS_URL="${ADO_BASE}/test/Runs/${LATEST_RUN_ID}/results?api-version=7.1-preview.6&outcomes=Failed&\$top=30"
          FAILED_TESTS=$(ado_api_call "$TEST_RESULTS_URL" 2>/dev/null) || true
          if [ -n "$FAILED_TESTS" ]; then
            FAILED_TEST_COUNT=$(echo "$FAILED_TESTS" | jq '.count // 0' 2>/dev/null || echo "0")
            if [ "$FAILED_TEST_COUNT" -gt 0 ]; then
              TEST_FAILURE_CONTEXT="

Failed tests ($FAILED_TEST_COUNT):
$(echo "$FAILED_TESTS" | jq -r '.value[]? | "- \(.testCaseTitle): \(.errorMessage // "no error message" | .[0:300])"' 2>/dev/null)"
              log "🧪 Found $FAILED_TEST_COUNT failed tests in build $FIRST_BUILD_ID (run $LATEST_RUN_ID)"
            fi
          fi
        fi
      fi
    fi

    # Also check the pipeline timeline for failed task details
    TIMELINE_FAILURE_CONTEXT=""
    if [ -n "$FIRST_BUILD_ID" ]; then
      TIMELINE_URL="${ADO_BASE}/build/builds/${FIRST_BUILD_ID}/timeline?api-version=7.1"
      TIMELINE=$(ado_api_call "$TIMELINE_URL" 2>/dev/null) || true
      if [ -n "$TIMELINE" ]; then
        FAILED_TASKS=$(echo "$TIMELINE" | jq -r '
          [.records[]?
           | select(.result == "failed" or .result == "succeededWithIssues")
           | select(.type == "Task")
           | {name, result, issues: [.issues[]? | select(.type == "error") | .message] | .[0:3]}
          ]' 2>/dev/null || echo "[]")
        FAILED_TASK_COUNT=$(echo "$FAILED_TASKS" | jq 'length' 2>/dev/null || echo "0")
        if [ "$FAILED_TASK_COUNT" -gt 0 ]; then
          TIMELINE_FAILURE_CONTEXT="

Failed/warning pipeline tasks:
$(echo "$FAILED_TASKS" | jq -r '.[] | "- \(.name) (\(.result)): \(.issues | join("; ") | .[0:200])"' 2>/dev/null)"
        fi
      fi
    fi

    # Build the failure context string
    LOG_SECTION=""
    if [ -n "${BUILD_LOG_SNIPPET:-}" ]; then
      LOG_SECTION="

Build log (last 5000 chars):
$BUILD_LOG_SNIPPET"
    fi

    BUILD_FAILURE_CONTEXT="

IMPORTANT: The following build validation policies are FAILING on this PR:
$(echo "$FAILING_POLICIES" | jq -r '.[] | "- \(.name): \(.status)"' 2>/dev/null)
${TIMELINE_FAILURE_CONTEXT}
${TEST_FAILURE_CONTEXT}
${LOG_SECTION}"
    log "🏗️  Build failure context added to Claude prompt"
  else
    log "🏗️  All build policies passing"
  fi
fi
# --- END best-effort build-failure enrichment — re-enable errexit ---
# Matching close of the `set +e` bracket above. Do NOT delete.
set -e
# Re-arm the global ERR trap disarmed at the top of this block.
arm_err_trap

# Ensure PR has a linked work item before any early-exit (ADO branch policy requires it)
# Must run even if there's nothing else to do, since the PR may have been created without one.
# Fetch PR_DETAILS if not already available (it's only set when PROJECT_ID was missing from payload)
if [ -z "${PR_DETAILS:-}" ]; then
  PR_DETAILS=$(ado_api_call "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}?api-version=7.1" 2>/dev/null) || true
fi
if [ -n "${PR_DETAILS:-}" ]; then
  # Skip work item linking for abandoned/completed PRs (prevents webhook feedback loops)
  PR_STATUS_NUM=$(echo "$PR_DETAILS" | jq -r '.status // 1' 2>/dev/null)
  if [ "$PR_STATUS_NUM" = "1" ] || [ "$PR_STATUS_NUM" = "active" ]; then
    ensure_pr_work_item "$PR_ID" "$REPO_ID" "$PR_DETAILS"
  else
    log "⏭️  Skipping work item linkage for non-active PR #${PR_ID} (status: ${PR_STATUS_NUM})"
  fi
fi

# Bail out entirely for abandoned/completed PRs — nothing to do
if [ -n "${PR_STATUS_NUM:-}" ] && [ "$PR_STATUS_NUM" != "1" ] && [ "$PR_STATUS_NUM" != "active" ]; then
  log "⏭️  PR #${PR_ID} is not active (status: ${PR_STATUS_NUM}), skipping"
  exit 0
fi

# --- Merge conflict detection via ADO API ---
HAS_MERGE_CONFLICT=false
MERGE_CONFLICT_CONTEXT=""
if [ -n "${PR_DETAILS:-}" ]; then
  MERGE_STATUS=$(echo "$PR_DETAILS" | jq -r '.mergeStatus // ""' 2>/dev/null)
  # mergeStatus values: "conflicts" or numeric 2 = conflict
  if [ "$MERGE_STATUS" = "conflicts" ] || [ "$MERGE_STATUS" = "2" ]; then
    HAS_MERGE_CONFLICT=true
    log "⚠️  PR #${PR_ID} has merge conflict (mergeStatus: ${MERGE_STATUS})"
  fi
fi

if [ "$HAS_MERGE_CONFLICT" = true ]; then
  log "🔍 Gathering merge conflict context..."

  git -C "$REPO_ROOT" -c gc.auto=0 fetch origin main 2>/dev/null || true
  RECENT_MAIN_COMMITS=$(git -C "$REPO_ROOT" log --oneline -10 origin/main 2>/dev/null || echo "unavailable")
  PR_TITLE=$(echo "$PR_DETAILS" | jq -r '.title // ""' 2>/dev/null)
  PR_DESCRIPTION=$(echo "$PR_DETAILS" | jq -r '.description // ""' 2>/dev/null | head -c 2000)

  MERGE_CONFLICT_CONTEXT="
IMPORTANT: This PR has a MERGE CONFLICT (ADO mergeStatus: conflicts). It cannot be merged.

PR title: ${PR_TITLE}
PR description (truncated): ${PR_DESCRIPTION}

Recent commits on main that may have caused the conflict:
${RECENT_MAIN_COMMITS}

YOUR TASK — Investigate and resolve the merge conflict:
1. Rebase the PR branch onto origin/main
2. If rebase has conflicts, examine the conflicting files and resolve them
3. Determine the correct resolution based on the content:
   a) RESOLVE & PUSH: If the conflict is resolvable (version bumps, config changes, etc.), resolve it, run tests, commit, and force-push
   b) ABANDON: If the PR is superseded or the change is no longer valid, abandon the PR via the ADO API with an explanation
4. After resolving, verify tests pass before pushing"
fi

# Now decide: if no comments AND no failing builds AND no merge conflict, we're done
# But first: requeue stale/queued build policies and run the policy gate (approve/auto-complete)
if [ "$HAS_UNRESOLVED_COMMENTS" = false ] && [ "$HAS_FAILING_BUILD" = false ] && [ "$HAS_MERGE_CONFLICT" = false ]; then
  # Requeue stale build policies (queued but never refreshed after a push)
  # Don't run full policy gate here — no worktree exists, so risk classification
  # would diff against main (wrong context). Full gate runs after Claude processes.
  if [ -n "${POLICY_EVALS:-}" ]; then
    requeue_expired_policies "$PR_ID" "$PROJECT_ID" "$POLICY_EVALS" || true
  fi
  log "✅ No unresolved comments and all policies passing — nothing to do"
  exit 0
fi

# Use git worktree for full isolation — each PR gets its own working directory
# so multiple PRs can be processed in parallel without checkout races.
# Keyed on PR id AND this router's PID so two routers for the SAME PR never share a
# directory. The per-PR lock should already serialize same-PR routers, but if that
# ever fails (e.g. the lock-acquire TOCTOU fixed above), a shared pr-<ID> path let
# the loser's cleanup rm -rf the winner's live worktree → the winner's next git op
# died exit 128 (PR #1420, 2026-06-10). A per-PID path makes cleanup touch only THIS
# run's directory, so concurrent routers are structurally incapable of deleting each
# other's worktree. Orphaned per-PID dirs (router SIGKILL'd before cleanup) are GC'd
# by prune_stale_worktrees() in start.sh, which globs every */ under the base.
WORK_DIR="$WORKTREE_DIR/pr-${PR_ID}-$$"

# Remove stale worktree if it exists from a previous run
if [ -d "$WORK_DIR" ]; then
  log "🧹 Cleaning up stale worktree at ${WORK_DIR}..."
  git -C "$REPO_ROOT" worktree remove --force "$WORK_DIR" 2>/dev/null || true
  # Always rm -rf — worktree remove may succeed in git's tracking but leave the dir
  rm -rf "$WORK_DIR"
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
fi

log "🌿 Creating worktree for PR #${PR_ID} at ${WORK_DIR}..."
log "🌿 Fetching main + source branch: ${SOURCE_BRANCH}..."
git -C "$REPO_ROOT" -c gc.auto=0 fetch origin main 2>&1 || log "⚠️  git fetch main failed"
if ! git -C "$REPO_ROOT" -c gc.auto=0 fetch origin "$SOURCE_BRANCH" 2>&1; then
  log "⚠️  git fetch failed for branch ${SOURCE_BRANCH} (may not exist on remote)"
fi

# Create worktree in detached HEAD mode, then checkout the branch.
# Detached first avoids "branch already checked out" errors from worktree add.
if ! git -C "$REPO_ROOT" worktree add --detach "$WORK_DIR" "origin/$SOURCE_BRANCH" 2>&1; then
  log "❌ Failed to create worktree at ${WORK_DIR}"
  exit 1
fi
# Create a local tracking branch inside the worktree so Claude can commit and push.
# Use -B to force-update if the branch already exists (e.g. from a previous run).
# If it fails (branch already checked out by main repo or another worktree),
# create a temporary local branch that pushes to the same remote ref.
if ! git -C "$WORK_DIR" checkout -B "$SOURCE_BRANCH" "origin/$SOURCE_BRANCH" 2>&1; then
  PR_BOT_BRANCH="pr-bot/pr-${PR_ID}"
  log "⚠️  Branch '${SOURCE_BRANCH}' in use by another worktree, using temp branch '${PR_BOT_BRANCH}'"
  if ! git -C "$WORK_DIR" checkout -B "$PR_BOT_BRANCH" "origin/$SOURCE_BRANCH" 2>&1; then
    log "❌ Failed to create temp branch '${PR_BOT_BRANCH}', aborting"
    exit 1
  fi
  # Configure push to target the real remote branch, not pr-bot/pr-*
  git -C "$WORK_DIR" config "branch.${PR_BOT_BRANCH}.remote" origin
  git -C "$WORK_DIR" config "branch.${PR_BOT_BRANCH}.merge" "refs/heads/${SOURCE_BRANCH}"
  # Set push.default=upstream in worktree-local config only (not repo-wide)
  # so git push uses the configured upstream regardless of branch name mismatch.
  git -C "$WORK_DIR" config --worktree push.default upstream 2>/dev/null \
    || git -C "$WORK_DIR" config --local push.default upstream
fi
log "🌿 Worktree ready on branch $(git -C "$WORK_DIR" branch --show-current)"

# Guard: confirm the worktree still exists before any git op that runs under set -e.
# With the per-PID $WORK_DIR (pr-<ID>-<PID>) a sibling router can no longer delete
# this directory, so the historical concurrent-cleanup race (PR #1408/#1420, exit
# 128) is closed at the source. This guard is retained purely as cheap defense so a
# genuinely missing worktree (e.g. the FS pruner reaped it, or a SIGKILL interrupted
# `worktree add`) yields a clear, classified failure (still non-zero → breaker backs
# off) rather than an opaque "Script failed at line NNN with exit code 128".
if [ ! -d "$WORK_DIR/.git" ] && [ ! -f "$WORK_DIR/.git" ]; then
  log "❌ Worktree at ${WORK_DIR} vanished before HEAD check — aborting this run"
  exit 1
fi

# WU3: Verify branch is fresh — if remote was force-pushed/rebased, reset to match
REMOTE_HEAD=$(git -C "$WORK_DIR" ls-remote origin "refs/heads/$SOURCE_BRANCH" 2>/dev/null | awk '{print $1}')
LOCAL_HEAD=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null)
if [ -n "$REMOTE_HEAD" ] && [ "$REMOTE_HEAD" != "$LOCAL_HEAD" ]; then
  log "⚠️  Branch diverged from remote (local: ${LOCAL_HEAD:0:8}, remote: ${REMOTE_HEAD:0:8}), resetting..."
  git -C "$WORK_DIR" reset --hard "origin/$SOURCE_BRANCH" 2>&1
fi

# WU11: Re-fetch PR details (may have changed since early check) for Claude prompt context
PR_DETAILS=$(ado_api_call "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}?api-version=7.1") || true

# Build policy context already fetched above (early policy check).
# Adjust Claude prompt based on what we're asking it to do.
# Add efficiency instructions to prevent max_turns issues.
EFFICIENCY_INSTRUCTIONS="
IMPORTANT EFFICIENCY RULES (you have limited turns):
- Do NOT read files one at a time. Batch file reads using multiple Read tool calls in parallel.
- Do NOT re-read files you've already seen. Keep track of what you've read.
- Make all related edits to a file in one Edit call, not multiple small edits.
- Run tests ONCE at the end, not after every change.
- Commit all changes in one commit, not multiple commits.
- Be concise in your reasoning — focus on code changes, not explanations.
- Do NOT create work items or link work items — the bot handles work item management automatically.
- Do NOT reply to or comment on PR review threads. Just make the code changes. The bot handles thread resolution automatically."

CAPPED_NOTE=""
if [ "$THREADS_CAPPED" = true ]; then
  CAPPED_NOTE="
NOTE: This PR has $TOTAL_UNRESOLVED unresolved comment threads but only the $MAX_THREADS most recent are shown. Address these first — the bot will process remaining threads in subsequent runs."
fi

if [ "$HAS_UNRESOLVED_COMMENTS" = true ] && [ "$HAS_FAILING_BUILD" = true ]; then
  CLAUDE_TASK="Address the unresolved review comments on this PR AND fix the failing build. Read the relevant files, make the code changes, run L0 tests if applicable (dotnet test --filter 'TestCategory=L0' --verbosity quiet), commit and push to the PR branch (${SOURCE_BRANCH}). Summarize what you changed.${CAPPED_NOTE}${BUILD_FAILURE_CONTEXT}${EFFICIENCY_INSTRUCTIONS}"
elif [ "$HAS_UNRESOLVED_COMMENTS" = true ]; then
  CLAUDE_TASK="Address the unresolved review comments on this PR. Read the relevant files, make the code changes, run L0 tests if applicable (dotnet test --filter 'TestCategory=L0' --verbosity quiet), commit and push to the PR branch (${SOURCE_BRANCH}). Summarize what you changed.${CAPPED_NOTE}${EFFICIENCY_INSTRUCTIONS}"
else
  # Only failing builds, no review comments
  CLAUDE_TASK="The build validation policies are FAILING on this PR. Investigate the build failure, fix the issue, run L0 tests locally (dotnet test --filter 'TestCategory=L0' --verbosity quiet), commit and push to the PR branch (${SOURCE_BRANCH}). Summarize what you changed.${BUILD_FAILURE_CONTEXT}${EFFICIENCY_INSTRUCTIONS}"
fi

# Prepend merge conflict context when present
if [ "$HAS_MERGE_CONFLICT" = true ]; then
  if [ -n "$CLAUDE_TASK" ] && { [ "$HAS_UNRESOLVED_COMMENTS" = true ] || [ "$HAS_FAILING_BUILD" = true ]; }; then
    CLAUDE_TASK="${MERGE_CONFLICT_CONTEXT}

Additionally: ${CLAUDE_TASK}"
  else
    CLAUDE_TASK="${MERGE_CONFLICT_CONTEXT}${EFFICIENCY_INSTRUCTIONS}"
  fi
fi

# Resolve token-savior MCP binary (install if needed)
TOKEN_SAVIOR_BIN=""
if [ "${ENABLE_TOKEN_SAVIOR:-true}" = "true" ]; then
  TOKEN_SAVIOR_BIN=$("$SCRIPT_DIR/setup-mcp.sh" 2>/dev/null) || TOKEN_SAVIOR_BIN=""
fi

if [ -n "$TOKEN_SAVIOR_BIN" ]; then
  MCP_CONFIG=$(jq -cn \
    --arg cmd "$TOKEN_SAVIOR_BIN" \
    --arg workspace "$WORK_DIR" \
    '{"mcpServers":{"token-savior-recall":{"type":"stdio","command":$cmd,"env":{"WORKSPACE_ROOTS":$workspace,"TOKEN_SAVIOR_CLIENT":"claude-code","TOKEN_SAVIOR_PROFILE":"optimized"}}}}')
  log "🔧 MCP config: token-savior-recall enabled"
else
  MCP_CONFIG='{"mcpServers":{}}'
  log "⚠️ token-savior-recall not available, running without MCP"
fi

# Invoke Claude Code with --from-pr for full PR context (diff, comments, metadata)
PR_URL="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_git/${REPO_NAME}/pullrequest/${PR_ID}"
log "🤖 Invoking: claude --from-pr ${PR_URL}"

# Pre-flight: verify Claude CLI is working before committing to a long timeout
if ! CLAUDE_VERSION=$(cd "$WORK_DIR" && claude --version 2>&1); then
  log "❌ Claude CLI failed (exit code $?): $CLAUDE_VERSION"
  exit 1
fi
if [ -z "$CLAUDE_VERSION" ]; then
  log "❌ Claude CLI not responding (--version returned empty), aborting"
  exit 1
fi
log "🤖 Claude CLI version: $CLAUDE_VERSION"

# Clear stale session/cache files from worktree (preserve settings.json for MCP/permission configs)
rm -rf "$WORK_DIR/.claude/worktrees" "$WORK_DIR/.claude/todos" "$WORK_DIR/.claude/sessions" 2>/dev/null || true

# Environment hardening for unattended runs
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-65536}"

CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-50}"
CLAUDE_MAX_RETRIES="${CLAUDE_MAX_RETRIES:-2}"  # retry up to 2 times on max_turns

# run_claude_session — Runs a single Claude session with timeout handling.
# Arguments: $1 = prompt text, $2 = session_id to continue (optional)
# Sets: CLAUDE_EXIT_CODE, CLAUDE_STDOUT_FILE, CLAUDE_STDERR_FILE
run_claude_session() {
  local prompt="$1"
  local continue_session="${2:-}"
  CLAUDE_EXIT_CODE=0

  local claude_args=(
    --print
    --output-format json
    --dangerously-skip-permissions
    --mcp-config "$MCP_CONFIG"
    --strict-mcp-config
    --max-turns "$CLAUDE_MAX_TURNS"
    --append-system-prompt "You are running in a memory-constrained CI environment. Prefer targeted file reads with line ranges over reading entire files. Avoid spawning Agent subprocesses. Summarize findings concisely rather than quoting large code blocks."
  )

  # Either continue a previous session or start fresh with --from-pr
  if [ -n "$continue_session" ]; then
    claude_args+=(--continue "$continue_session")
  else
    claude_args+=(--from-pr "$PR_URL")
  fi

  claude_args+=(-p "$prompt")

  pushd "$WORK_DIR" > /dev/null
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=30 "$CLAUDE_TIMEOUT" claude \
      "${claude_args[@]}" \
      > "$CLAUDE_STDOUT_FILE" 2> >(tee "$CLAUDE_STDERR_FILE" >&2) < /dev/null || CLAUDE_EXIT_CODE=$?
  else
    STDERR_PIPE="$STATE_DIR/pr-${PR_ID}-stderr-pipe"
    rm -f "$STDERR_PIPE"
    mkfifo "$STDERR_PIPE"
    tee "$CLAUDE_STDERR_FILE" < "$STDERR_PIPE" >&2 &
    TEE_PID=$!
    claude \
      "${claude_args[@]}" \
      > "$CLAUDE_STDOUT_FILE" 2>"$STDERR_PIPE" < /dev/null &
    CLAUDE_PID=$!
    TIMED_OUT=false
    (
      trap 'exit 0' TERM
      sleep "$CLAUDE_TIMEOUT"
      if kill -0 "$CLAUDE_PID" 2>/dev/null; then
        log "⏰ Timeout reached (${CLAUDE_TIMEOUT}s), sending SIGTERM to Claude (PID: $CLAUDE_PID)"
        kill "$CLAUDE_PID" 2>/dev/null || true
        sleep 30
        if kill -0 "$CLAUDE_PID" 2>/dev/null; then
          kill -9 "$CLAUDE_PID" 2>/dev/null || true
        fi
      fi
    ) &
    WATCHDOG_PID=$!
    wait "$CLAUDE_PID" 2>/dev/null || CLAUDE_EXIT_CODE=$?
    if ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
      TIMED_OUT=true
    fi
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    wait "$TEE_PID" 2>/dev/null || true
    rm -f "$STDERR_PIPE"
    if [ "$TIMED_OUT" = true ] && [ "$CLAUDE_EXIT_CODE" -gt 128 ]; then
      CLAUDE_EXIT_CODE=124
    fi
  fi
  popd > /dev/null
}

# Write output to files instead of capturing in variable
CLAUDE_STDOUT_FILE="$STATE_DIR/pr-${PR_ID}-stdout.log"
CLAUDE_STDERR_FILE="$STATE_DIR/pr-${PR_ID}-stderr.log"

# --- Session loop with max_turns retry ---
# If Claude hits max_turns, extract its session_id and progress summary,
# then continue in a new session with focused instructions.
ATTEMPT=0
CONTINUE_SESSION=""
CURRENT_PROMPT="$CLAUDE_TASK"

while [ "$ATTEMPT" -le "$CLAUDE_MAX_RETRIES" ]; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -gt 1 ]; then
    log "🔄 Retry attempt $ATTEMPT/$((CLAUDE_MAX_RETRIES + 1)) — continuing from previous session"
  fi

  run_claude_session "$CURRENT_PROMPT" "$CONTINUE_SESSION"

  if [ "$CLAUDE_EXIT_CODE" -eq 124 ]; then
    log "⏰ Claude Code timed out after ${CLAUDE_TIMEOUT}s for PR #${PR_ID}"
    log "⏰ Stdout (last 2000 chars): $(tail -c 2000 "$CLAUDE_STDOUT_FILE" 2>/dev/null)"
    break  # timeout is not retryable
  fi

  # Check if this was a max_turns exit (retryable)
  IS_MAX_TURNS=false
  SESSION_ID=""
  if jq -e '.type == "result"' "$CLAUDE_STDOUT_FILE" >/dev/null 2>&1; then
    TERMINAL_REASON=$(jq -r '.terminal_reason // ""' "$CLAUDE_STDOUT_FILE" 2>/dev/null)
    SESSION_ID=$(jq -r '.session_id // ""' "$CLAUDE_STDOUT_FILE" 2>/dev/null)
    if [ "$TERMINAL_REASON" = "max_turns" ]; then
      IS_MAX_TURNS=true
    fi
  fi

  if [ "$IS_MAX_TURNS" = true ] && [ "$ATTEMPT" -le "$CLAUDE_MAX_RETRIES" ] && [ -n "$SESSION_ID" ]; then
    log "🔄 Claude hit max_turns ($CLAUDE_MAX_TURNS) — will continue session $SESSION_ID"

    # Check if Claude made any commits we should preserve
    COMMITS_SO_FAR=$(git -C "$WORK_DIR" log "origin/${SOURCE_BRANCH}..HEAD" --oneline 2>/dev/null || true)
    if [ -n "$COMMITS_SO_FAR" ]; then
      COMMIT_COUNT=$(echo "$COMMITS_SO_FAR" | wc -l | tr -d ' ')
      log "🔄 Session made $COMMIT_COUNT commit(s) so far — continuing to finish remaining work"
    fi

    # Build continuation prompt — focused, with progress context
    CONTINUE_SESSION="$SESSION_ID"
    CURRENT_PROMPT="You ran out of turns in the previous session. Continue where you left off. Focus on:
1. If you have uncommitted changes, commit and push them now.
2. If there are remaining review comments or build failures you haven't addressed, fix them.
3. Run tests if you haven't already (dotnet test --filter 'TestCategory=L0' --verbosity quiet).
4. Push all commits to the PR branch (${SOURCE_BRANCH}).
5. Summarize what you changed across both sessions.
Do NOT re-read files you already read. Do NOT redo work already done. Be efficient — you have $CLAUDE_MAX_TURNS turns."
  else
    # Not a max_turns issue, or out of retries — exit loop
    if [ "$IS_MAX_TURNS" = true ]; then
      log "⚠️  Claude hit max_turns after $ATTEMPT attempt(s) — no more retries"
    elif [ "$CLAUDE_EXIT_CODE" -ne 0 ]; then
      log "⚠️  Claude Code exited with code $CLAUDE_EXIT_CODE"
      log "⚠️  Stdout (last 2000 chars): $(tail -c 2000 "$CLAUDE_STDOUT_FILE" 2>/dev/null)"
      # Surface stderr too — a non-zero exit with empty stdout (the common
      # config-error shape) previously logged nothing actionable, so a permanent
      # model/auth misconfig looked identical to a transient blip.
      CLAUDE_STDERR_TAIL=$(tail -c 2000 "$CLAUDE_STDERR_FILE" 2>/dev/null)
      [ -n "$CLAUDE_STDERR_TAIL" ] && log "⚠️  Stderr (last 2000 chars): $CLAUDE_STDERR_TAIL"
      # Flag config-level (non-transient) rejections distinctly: a bad ANTHROPIC_MODEL
      # alias or a revoked token will NOT fix itself on retry, so it must not hide behind
      # the generic "exited with code N". Match the proxy's model-rejection wording and
      # the HTTP 4xx auth/authorization codes.
      if printf '%s' "$CLAUDE_STDERR_TAIL" | grep -qiE 'model is not available|not_found_error|authentication_error|permission_error|x-api-key|invalid[ _-]?api[ _-]?key|HTTP (400|401|403)|"?status"?:? ?(400|401|403)'; then
        log "🛑 Claude failure looks CONFIG-LEVEL (model/auth rejection), not transient — check ANTHROPIC_MODEL / ANTHROPIC_AUTH_TOKEN in .secrets.env (a retry will not fix this)"
      fi
    fi
    break
  fi
done

log "✅ Claude Code completed for PR #${PR_ID} (exit code: $CLAUDE_EXIT_CODE, attempts: $ATTEMPT)"
log "📊 Output size: $(wc -c < "$CLAUDE_STDOUT_FILE" 2>/dev/null || echo 0) bytes (stdout), $(wc -c < "$CLAUDE_STDERR_FILE" 2>/dev/null || echo 0) bytes (stderr)"

# Log token usage from Claude output
if [ -f "$CLAUDE_STDOUT_FILE" ]; then
  local_usage=$(jq -r '.usage | "input=\(.input_tokens // 0) output=\(.output_tokens // 0) cache_read=\(.cache_read_input_tokens // 0)"' "$CLAUDE_STDOUT_FILE" 2>/dev/null) || true
  [ -n "$local_usage" ] && [ "$local_usage" != "null" ] && log "📊 Token usage: $local_usage"

  # Log tool call stats
  local_tools=$(jq '[.messages[]? | select(.role=="assistant") | .content[]? | select(.type=="tool_use")] | group_by(.name) | map({name: .[0].name, count: length}) | sort_by(-.count) | .[:10]' "$CLAUDE_STDOUT_FILE" 2>/dev/null) || true
  if [ -n "$local_tools" ] && [ "$local_tools" != "null" ] && [ "$local_tools" != "[]" ]; then
    log "🔧 Tool usage: $local_tools"
  fi
fi

# Parse Claude output envelope to determine success
# Claude CLI with --output-format json returns:
#   {"type":"result", "result":"...", "usage":{...}}
# Pipe directly from file to jq to avoid loading large output into bash variables.
CLAUDE_RESULT=""
CLAUDE_SUCCESS=false
# YIELD_REQUESTED flips to true when the recovery push loses a --force-with-lease
# race (a human/agent pushed concurrently) and we could not safely rebase+retry
# within the bounded budget. It maps to the dedicated yield exit code (75) at the
# tail so cleanup() requeues the PR WITHOUT a circuit penalty or .crashed marker.
YIELD_REQUESTED=false

# Skip JSON parsing on timeout — output is likely truncated/invalid
if [ "$CLAUDE_EXIT_CODE" -eq 124 ]; then
  log "⚠️  Skipping output parsing — process was killed by timeout"
elif jq -e '.type == "result"' "$CLAUDE_STDOUT_FILE" >/dev/null 2>&1; then
  CLAUDE_RESULT=$(jq -r '.result // ""' "$CLAUDE_STDOUT_FILE")
  # Even max_turns is partial success if commits were pushed
  TERMINAL_REASON=$(jq -r '.terminal_reason // ""' "$CLAUDE_STDOUT_FILE" 2>/dev/null)
  log "📊 Claude result (first 500 chars): $(echo "$CLAUDE_RESULT" | head -c 500)"

  # WU1: Git-based push verification — check if commits were actually pushed
  # 1. Check for uncommitted changes in the worktree
  if [ -d "${WORK_DIR:-}" ]; then
    UNCOMMITTED_CHANGES=$(git -C "$WORK_DIR" status --porcelain 2>/dev/null | head -5)
    if [ -n "$UNCOMMITTED_CHANGES" ]; then
      log "⚠️  Uncommitted changes detected in worktree:"
      log "    $(echo "$UNCOMMITTED_CHANGES" | head -3)"
    fi

    # 2. Check for unpushed commits (fetch first to ensure remote refs are current)
    git -C "$WORK_DIR" fetch origin "$SOURCE_BRANCH" 2>/dev/null || true
    UNPUSHED=$(git -C "$WORK_DIR" log "origin/${SOURCE_BRANCH}..HEAD" --oneline 2>/dev/null || true)
    if [ -n "$UNPUSHED" ]; then
      UNPUSHED_COUNT=$(echo "$UNPUSHED" | wc -l | tr -d ' ')
      log "⚠️  Found $UNPUSHED_COUNT unpushed commit(s), attempting recovery push (--force-with-lease)..."
      # Push safety under concurrency: use --force-with-lease so we only overwrite
      # the remote ref if it still points where our fetch saw it. If a human or an
      # interactive agent pushed in the meantime, the lease is stale and git rejects
      # the push instead of clobbering their commit. On rejection we fetch + rebase
      # our commits on top of theirs and retry, up to PR_BOT_PUSH_RETRIES times. If
      # it is STILL contended after the budget, we YIELD (exit 75) rather than crash:
      # the slot frees for other PRs and the heartbeat re-dispatches this one ~5min
      # later, by which point the concurrent driver has usually settled.
      PR_BOT_PUSH_RETRIES="${PR_BOT_PUSH_RETRIES:-2}"
      _push_ok=false
      _push_is_concurrency=false
      _attempt=0
      while :; do
        _push_stderr=$(mktemp)
        if git -C "$WORK_DIR" push --force-with-lease origin HEAD:"refs/heads/${SOURCE_BRANCH}" 2>"$_push_stderr"; then
          log "✅ Recovery push succeeded"
          _push_ok=true
          rm -f "$_push_stderr"
          break
        fi
        _push_err=$(cat "$_push_stderr" 2>/dev/null)
        rm -f "$_push_stderr"
        # Distinguish concurrency rejections (stale lease / tip moved) from
        # non-transient errors (expired PAT, branch policy, network outage).
        # Only concurrency races are retryable; everything else should fail
        # hard (exit 1) so the circuit breaker engages rather than yielding
        # indefinitely via exit 75 (Thread 10539).
        if echo "$_push_err" | grep -qiE 'stale info|failed to push|fetch first|non-fast-forward|tip.*behind|cannot lock ref|remote rejected.*force_with_lease'; then
          _push_is_concurrency=true
        else
          log "❌ Recovery push failed with non-transient error (not a concurrency race):"
          log "❌ $_push_err"
          _push_is_concurrency=false
          break
        fi
        _attempt=$((_attempt + 1))
        if [ "$_attempt" -gt "$PR_BOT_PUSH_RETRIES" ]; then
          log "🤝 Recovery push still rejected after ${PR_BOT_PUSH_RETRIES} rebase retries — branch is being driven concurrently"
          break
        fi
        log "↩️  Recovery push rejected (lease stale — concurrent push), rebasing and retrying (${_attempt}/${PR_BOT_PUSH_RETRIES})..."
        git -C "$WORK_DIR" fetch origin "$SOURCE_BRANCH" 2>/dev/null || true
        if ! git -C "$WORK_DIR" rebase "origin/${SOURCE_BRANCH}" 2>&1; then
          log "⚠️  Rebase onto origin/${SOURCE_BRANCH} hit conflicts — aborting rebase, will yield"
          git -C "$WORK_DIR" rebase --abort 2>/dev/null || true
          break
        fi
      done
      if [ "$_push_ok" != true ]; then
        if [ "$_push_is_concurrency" = true ]; then
          log "❌ Recovery push FAILED (concurrency) — commits are stranded; yielding PR #${PR_ID} for later re-dispatch"
          YIELD_REQUESTED=true
        else
          log "❌ Recovery push FAILED (non-transient) — will NOT yield; circuit breaker will engage"
          # Do NOT set YIELD_REQUESTED — fall through to exit 1 so the circuit
          # breaker sees a real failure and backs off, rather than silently
          # re-dispatching every ~5min for a permanently broken push.
        fi
      fi
    fi

    # 3. Verify push via ls-remote vs local HEAD
    LOCAL_HEAD_AFTER=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
    REMOTE_HEAD_AFTER=$(git -C "$WORK_DIR" ls-remote origin "refs/heads/$SOURCE_BRANCH" 2>/dev/null | awk '{print $1}')
    if [ -n "$REMOTE_HEAD_AFTER" ] && [ "$LOCAL_HEAD_AFTER" = "$REMOTE_HEAD_AFTER" ]; then
      CLAUDE_SUCCESS=true
      log "✅ Push verified: local HEAD ($LOCAL_HEAD_AFTER) matches remote"
    elif [ -n "$REMOTE_HEAD_AFTER" ] && [ "$LOCAL_HEAD_AFTER" != "$REMOTE_HEAD_AFTER" ]; then
      log "❌ Push verification FAILED: local=${LOCAL_HEAD_AFTER:0:8} remote=${REMOTE_HEAD_AFTER:0:8}"
      # Do NOT fall back to text heuristic here — push definitively failed
    else
      # ls-remote failed (network issue?) — fall back to text heuristic
      log "⚠️  Could not verify push via ls-remote, falling back to text heuristic"
      if echo "$CLAUDE_RESULT" | grep -qiE '(committed|pushed|fixed|updated|changed|applied|created)'; then
        CLAUDE_SUCCESS=true
      fi
    fi
  else
    # No worktree — fall back to text heuristic
    if echo "$CLAUDE_RESULT" | grep -qiE '(committed|pushed|fixed|updated|changed|applied|created)'; then
      CLAUDE_SUCCESS=true
    fi
  fi

  log "📊 Claude output parsed successfully (success=$CLAUDE_SUCCESS)"
else
  log "⚠️  Could not parse Claude output as JSON — treating as failure"
  log "⚠️  Stdout (last 2000 chars): $(tail -c 2000 "$CLAUDE_STDOUT_FILE" 2>/dev/null)"
  log "⚠️  Stderr (last 2000 chars): $(tail -c 2000 "$CLAUDE_STDERR_FILE" 2>/dev/null)"
fi

# Clean up output files (keep on failure for post-mortem debugging)
if [ "$CLAUDE_SUCCESS" = true ]; then
  rm -f "$CLAUDE_STDOUT_FILE" "$CLAUDE_STDERR_FILE"
else
  log "📁 Preserving output files for debugging: $CLAUDE_STDOUT_FILE, $CLAUDE_STDERR_FILE"
fi

# Update state
jq -n \
  --arg commit "$(git -C "${WORK_DIR:-$REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo 'unknown')" \
  --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson success "$CLAUDE_SUCCESS" \
  '{
    lastProcessedCommit: $commit,
    lastProcessedTimestamp: $timestamp,
    lastRunSuccess: $success
  }' > "$STATE_FILE"

log "💾 State updated (success: $CLAUDE_SUCCESS)"

# Run policy gate on success (risk classify → approve → auto-complete → requeue stale policies)
# Runs even without thread IDs — heartbeat-recovered PRs may only have stale build policies.
if [ "$CLAUDE_SUCCESS" = true ]; then
  run_policy_gate "$PR_ID" "$REPO_ID" "$PROJECT_ID" "${WORK_DIR:-$REPO_ROOT}" "${SKIP_AUTO:-0}" || true
fi

# Resolve threads if Claude successfully addressed them
if [ "$CLAUDE_SUCCESS" = true ] && [ -n "$THREAD_IDS" ]; then
  log "🔒 Resolving addressed threads..."
  "$SCRIPT_DIR/ado_resolve.sh" "$PR_ID" "$REPO_ID" "$THREAD_IDS"
elif [ -n "$THREAD_IDS" ]; then
  log "⚠️  Skipping thread resolution — Claude did not confirm successful changes"
fi

log "🏁 PR #${PR_ID} processed (success=$CLAUDE_SUCCESS)"

# Propagate the success verdict to the process exit code. Without this the
# script falls off EOF after the log() above and exits 0 even when
# CLAUDE_SUCCESS=false (timeout/124, unparseable output, failed push) — which
# made cleanup() record circuit success, release the lease as "done", skip the
# .crashed/.failures marker, and report "completed successfully" to the parent.
# That false-success is exactly what put slow/build-verifying PRs on a silent
# re-queue treadmill (the circuit breaker never saw a failure to back off on).
#
# THREE terminal states (the exit-code contract cleanup() keys on):
#   0  → success: lease "done", circuit success, parent logs "completed".
#   75 → YIELD (EX_TEMPFAIL): we did real work but lost a push race to a concurrent
#        driver. Distinct from failure so cleanup() releases the lease as a NON-active
#        status (heartbeat re-dispatches), requeues with #22 dedup, and does NOT trip
#        the circuit breaker or write .crashed — this is contention, not a defect.
#   1  → failure: lease "failed", circuit failure, .crashed marker, crash recovery.
if [ "$CLAUDE_SUCCESS" = true ]; then
  exit 0
elif [ "$YIELD_REQUESTED" = true ]; then
  log "🤝 PR #${PR_ID} yielding (exit 75) — branch contended; releasing slot, heartbeat will re-dispatch"
  exit 75
else
  log "❌ PR #${PR_ID} did NOT publish (success=false) — exiting non-zero so the circuit breaker and crash recovery engage"
  exit 1
fi
