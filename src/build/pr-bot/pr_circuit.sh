#!/usr/bin/env bash
# pr_circuit.sh — Per-PR circuit breaker for the Left Jab Bot.
#
# Quarantines a PR that keeps failing on the SAME head commit, with exponential
# backoff, so that a single malformed API response (or any deterministic crash)
# can never monopolise the bot via the heartbeat re-queue loop again. This is the
# self-healing guard for the PR #1340 class of failure (bad response → router
# crash → heartbeat re-queues same HEAD → crash → repeat, forever).
#
# A NEW commit (different SHA) RESETS the breaker — fresh code always gets a
# fresh attempt.
#
# Sourced by:
#   - pr_router.sh  : gate BEFORE lease acquisition + outcome recording in cleanup()
#   - pr_heartbeat.sh : gate BEFORE re-queuing a deferred payload
# Both callers already source ../shared/ado_api.sh (ado_api_call) and define
# ADO_BASE + STATE_DIR, which this helper reuses to post a one-time human alert.
#
# State file: $STATE_DIR/pr-<id>.failures (JSON)
#   { count, headCommit, lastFailureTs, nextRetryEpoch, lastExitCode, commentPosted }
# Atomic writes (jq -n > tmp && mv); tolerant reads (// 0, // "").
#
# Public API:
#   circuit_is_open <pr_id> <head>          # 0 = OPEN (skip), 1 = CLOSED (proceed)
#   circuit_record_failure <pr_id> <head> <exit_code>
#   circuit_record_success <pr_id> <head>
#   circuit_reset <pr_id>
#
# Side effects: circuit_is_open sets CIRCUIT_RETRY_IN (seconds until next retry)
# and CIRCUIT_STATE ("backoff" | "quarantined") so the caller can log a precise
# "retry in Ns" message.

# Guard against double-sourcing (a parent may source this transitively).
if [ -n "${_PR_CIRCUIT_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_PR_CIRCUIT_SH_LOADED=1

# --- Tunables (overridable via config.env / environment; no redeploy to tune) ---
# Backoff window (seconds) per consecutive failure count on the same commit:
#   1 → 5m, 2 → 15m, 3 → 45m, 4 → 2h, ≥5 → 6h quarantine (+ one-time human alert).
CIRCUIT_BACKOFF_1="${CIRCUIT_BACKOFF_1:-300}"                    # 5 minutes
CIRCUIT_BACKOFF_2="${CIRCUIT_BACKOFF_2:-900}"                    # 15 minutes
CIRCUIT_BACKOFF_3="${CIRCUIT_BACKOFF_3:-2700}"                   # 45 minutes
CIRCUIT_BACKOFF_4="${CIRCUIT_BACKOFF_4:-7200}"                   # 2 hours
CIRCUIT_BACKOFF_QUARANTINE="${CIRCUIT_BACKOFF_QUARANTINE:-21600}" # 6 hours
# Failure count at/after which the PR is considered quarantined (human alert).
CIRCUIT_QUARANTINE_THRESHOLD="${CIRCUIT_QUARANTINE_THRESHOLD:-5}"

# Exposed to callers by circuit_is_open.
CIRCUIT_RETRY_IN=0
CIRCUIT_STATE=""

# Resolve the state file path for a PR. Echoes empty if STATE_DIR is unset.
_circuit_state_file() {
  local pr_id="$1"
  [ -n "${STATE_DIR:-}" ] || { echo ""; return; }
  echo "${STATE_DIR}/pr-${pr_id}.failures"
}

# Map a (1-based) failure count to its backoff window in seconds.
_circuit_backoff_for() {
  local count="$1"
  case "$count" in
    1) echo "$CIRCUIT_BACKOFF_1" ;;
    2) echo "$CIRCUIT_BACKOFF_2" ;;
    3) echo "$CIRCUIT_BACKOFF_3" ;;
    4) echo "$CIRCUIT_BACKOFF_4" ;;
    *) echo "$CIRCUIT_BACKOFF_QUARANTINE" ;;  # ≥5 (and defensive ≤0)
  esac
}

# circuit_is_open <pr_id> <head>
#   Returns 0 (OPEN — caller should SKIP) or 1 (CLOSED — caller should PROCEED).
#   OPEN iff: a state file exists AND its headCommit matches <head> AND we are
#   still inside the backoff window (now < nextRetryEpoch).
#   Missing file, empty head, or a changed head ⇒ CLOSED (fresh attempt).
#   On OPEN, sets CIRCUIT_RETRY_IN (secs remaining) and CIRCUIT_STATE.
circuit_is_open() {
  local pr_id="$1" head="${2:-}"
  CIRCUIT_RETRY_IN=0
  CIRCUIT_STATE=""

  # Never key on an empty head — we can't tell commits apart, so always proceed.
  [ -n "$head" ] || return 1

  local file
  file="$(_circuit_state_file "$pr_id")"
  [ -n "$file" ] && [ -f "$file" ] || return 1   # no prior failures → closed

  local stored_head count next now
  stored_head="$(jq -r '.headCommit // ""' "$file" 2>/dev/null)"
  # Different commit (fresh code) ⇒ breaker resets implicitly ⇒ closed.
  [ "$stored_head" = "$head" ] || return 1

  count="$(jq -r '.count // 0' "$file" 2>/dev/null)"
  next="$(jq -r '.nextRetryEpoch // 0' "$file" 2>/dev/null)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  [[ "$next" =~ ^[0-9]+$ ]] || next=0
  now="$(date +%s)"

  if [ "$now" -lt "$next" ]; then
    CIRCUIT_RETRY_IN=$(( next - now ))
    if [ "$count" -ge "$CIRCUIT_QUARANTINE_THRESHOLD" ]; then
      CIRCUIT_STATE="quarantined"
    else
      CIRCUIT_STATE="backoff"
    fi
    return 0   # OPEN — skip
  fi

  # Backoff window elapsed ⇒ allow a single probe retry.
  return 1     # CLOSED — proceed
}

# circuit_record_failure <pr_id> <head> <exit_code>
#   Increments the failure streak (resetting it when the head changed), schedules
#   the next retry per the backoff table, and posts a one-time human alert when
#   the quarantine threshold is first reached on this commit. Best-effort; never
#   fails the caller.
circuit_record_failure() {
  local pr_id="$1" head="${2:-}" exit_code="${3:-1}"

  # Without a key commit we cannot maintain a per-commit streak — skip silently.
  [ -n "$head" ] || return 0

  local file
  file="$(_circuit_state_file "$pr_id")"
  [ -n "$file" ] || return 0

  local prev_head prev_count prev_comment
  if [ -f "$file" ]; then
    prev_head="$(jq -r '.headCommit // ""' "$file" 2>/dev/null)"
    prev_count="$(jq -r '.count // 0' "$file" 2>/dev/null)"
    prev_comment="$(jq -r '.commentPosted // false' "$file" 2>/dev/null)"
  else
    prev_head=""
    prev_count=0
    prev_comment="false"
  fi
  [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0

  # New commit (or first-ever failure) ⇒ start a fresh streak + re-arm the alert.
  local count
  if [ "$prev_head" != "$head" ]; then
    count=1
    prev_comment="false"
  else
    count=$(( prev_count + 1 ))
  fi

  local now backoff next
  now="$(date +%s)"
  backoff="$(_circuit_backoff_for "$count")"
  next=$(( now + backoff ))

  # Post the one-time quarantine alert when first crossing the threshold.
  local comment_posted="$prev_comment"
  if [ "$count" -ge "$CIRCUIT_QUARANTINE_THRESHOLD" ] && [ "$prev_comment" != "true" ]; then
    if _circuit_post_alert "$pr_id" "$head" "$count" "$exit_code" "$backoff"; then
      comment_posted="true"
    fi
  fi

  local posted_json="false"
  [ "$comment_posted" = "true" ] && posted_json="true"

  # Atomic write: build into a temp file then rename over the real one.
  local tmp="${file}.tmp.$$"
  if jq -n \
      --argjson count "$count" \
      --arg head "$head" \
      --argjson ts "$now" \
      --argjson next "$next" \
      --arg code "$exit_code" \
      --argjson posted "$posted_json" \
      '{count:$count, headCommit:$head, lastFailureTs:$ts, nextRetryEpoch:$next, lastExitCode:$code, commentPosted:$posted}' \
      > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# circuit_record_success <pr_id> [head]
#   Clears all breaker state for the PR (the failure streak is broken). The
#   optional <head> is accepted for call-site symmetry with circuit_record_failure
#   but is unused — success clears the streak regardless of which commit succeeded.
circuit_record_success() {
  local pr_id="$1"
  local file
  file="$(_circuit_state_file "$pr_id")"
  [ -n "$file" ] && rm -f "$file" 2>/dev/null
  return 0
}

# circuit_reset <pr_id>
#   Hard reset (ops + the #1340 reset). Identical to a success clear.
circuit_reset() {
  circuit_record_success "$1"
}

# _circuit_post_alert <pr_id> <head> <count> <exit_code> <backoff_secs>
#   Posts a single human-facing alert comment on the PR via ADO. Best-effort:
#   returns 0 only when the POST appears to have succeeded (so commentPosted is
#   only latched on success). Uses ado_api_call + ADO_BASE + REPO_ID if present;
#   if any are unavailable it returns non-zero so the alert is retried next time.
_circuit_post_alert() {
  local pr_id="$1" head="$2" count="$3" exit_code="$4" backoff="$5"

  command -v ado_api_call >/dev/null 2>&1 || return 1
  [ -n "${ADO_BASE:-}" ] || return 1
  local repo="${REPO_ID:-}"
  [ -n "$repo" ] || return 1

  local hours short_head content
  hours=$(( backoff / 3600 ))
  short_head="${head:0:8}"
  content="🤖 **Left Jab Bot**: This PR has failed automated processing ${count} times in a row on the same commit (\`${short_head}\`, last exit code ${exit_code}).

It is now **quarantined for ~${hours}h** to stop a retry loop. Automated retries will continue to back off; pushing a **new commit** clears the quarantine immediately. Please review the failing build/checks manually.

<!-- pr-bot-circuit-breaker:PR-${pr_id}:${head} -->"

  local body
  body="$(jq -n --arg c "$content" '{comments:[{parentCommentId:0,content:$c,commentType:1}],status:4}')" || return 1
  ado_api_call "${ADO_BASE}/git/repositories/${repo}/pullRequests/${pr_id}/threads?api-version=7.1" "POST" "$body" >/dev/null 2>&1 || return 1
  return 0
}
