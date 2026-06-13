#!/usr/bin/env bash
set -euo pipefail

# pr_heartbeat.sh — Periodic orphan PR recovery via ADO polling
# Runs as a background loop alongside start.sh.
# Every HEARTBEAT_INTERVAL_SECS, polls active PRs and dispatches
# work for any that have unresolved actionable comments but no active lease.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.pr-bot-state}"
HEARTBEAT_INTERVAL_SECS="${HEARTBEAT_INTERVAL_SECS:-300}"

log() { echo "[$(date '+%H:%M:%S')] [heartbeat@${HOSTNAME}] $*"; }

# Detect a deliberate [marker] directive in free text without false-matching prose
# that merely mentions it (must mirror pr_router.sh::pr_text_has_directive exactly,
# or the two gates disagree). Directive = marker at line start (optional leading
# spaces + single list/quote bullet), NOT backticked/buried mid-sentence.
pr_text_has_directive() {
  local _text="$1" _marker="$2"
  printf '%s' "$_text" | grep -qiE "^[[:space:]]*([-*>][[:space:]]+)?\[${_marker}\]([[:space:]]|[:.]|\$)"
}

# Source shared utilities
source "$SCRIPT_DIR/../shared/ado_api.sh"
if [ -f "$SCRIPT_DIR/../shared/ado_auth.sh" ]; then
  source "$SCRIPT_DIR/../shared/ado_auth.sh"
fi
# Circuit breaker — skip re-queuing PRs whose breaker is open. The heartbeat is
# the re-queuer, so this gate is the highest-leverage stop for the #1340 crash
# loop (router crash → heartbeat re-queues same HEAD → crash → repeat).
source "$SCRIPT_DIR/pr_circuit.sh"
source "$SCRIPT_DIR/pr_constants.sh"

ADO_BASE="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis"
ADO_REPO="${ADO_REPO:-your-repo}"

# Get repository ID
get_repo_id() {
  local response
  response=$(ado_api_call "${ADO_BASE}/git/repositories/${ADO_REPO}?api-version=7.1" 2>/dev/null) || return 1
  echo "$response" | jq -r '.id // empty'
}

# Check if a PR has an active (non-expired) lease
pr_has_active_lease() {
  local pr_id="$1" repo_id="$2"
  local now
  now=$(date +%s)
  local grace=60

  local threads_json
  threads_json=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1" 2>/dev/null) || return 0

  local active_lease
  active_lease=$(echo "$threads_json" | jq -r --argjson now "$now" --argjson grace "$grace" '
    [.value[]
     | .comments[]?
     | .content // ""
     | capture("<!-- pr-bot-lease:(?<json>\\{[^}]+\\}) -->")
     | .json | fromjson
     | select(.expires + $grace > $now)
     | select(.status != "done" and .status != "failed")
    ] | first // empty' 2>/dev/null)

  [ -n "$active_lease" ]
}

# Check if a PR has actionable work (unresolved comments or failing builds)
pr_has_actionable_work() {
  local pr_id="$1" repo_id="$2"

  # Check for unresolved non-system comment threads
  local threads_json
  threads_json=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1" 2>/dev/null) || return 1

  local unresolved_count
  unresolved_count=$(echo "$threads_json" | jq '
    [.value[]
     | select(.status == "active" or .status == null)
     | select(.properties.CodeReviewThreadType.["$value"] != "VoteUpdate")
     | select([.comments[] | select(.commentType != "system")] | length > 0)
    ] | length' 2>/dev/null || echo "0")

  if [ "$unresolved_count" -gt 0 ]; then
    return 0  # Has actionable work
  fi

  # Check for failing build policies. Gate on the ADO "Build" policy type id
  # (0609b952-…) so that non-build policies which also report status="rejected" —
  # notably "Require a merge strategy" (rejected until a strategy is picked at
  # auto-complete time) — are NOT counted as actionable work. Counting them caused
  # the heartbeat to re-dispatch a PR forever while its build was already green
  # (observed: PR #1376 looped on every ~5-min heartbeat). Mirrors the same guard in
  # pr_router.sh's failing-build detection.
  local project_id
  project_id=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}?api-version=7.1" 2>/dev/null | jq -r '.repository.project.id // empty') || true
  [ -z "$project_id" ] && project_id="$ADO_PROJECT"

  local policy_url="${ADO_BASE}/policy/evaluations?artifactId=$(printf '%s' "vstfs:///CodeReview/CodeReviewId/${project_id}/${pr_id}" | jq -sRr @uri)&api-version=7.1-preview"
  local policy_evals
  policy_evals=$(ado_api_call "$policy_url" 2>/dev/null) || return 1

  local failing_count
  failing_count=$(echo "$policy_evals" | jq --arg bpt "$BUILD_POLICY_TYPE_ID" '[.value[]? | select((.status == "rejected" or .status == "broken") and .configuration.type.id == $bpt)] | length' 2>/dev/null || echo "0")

  [ "$failing_count" -gt 0 ]
}

# Check if a PR is "ready but unmerged" — the recovery gap behind PR #1384.
#
# A worker can resolve every review thread and turn all builds green, then have its
# FINAL step (cast the author merge vote + arm auto-complete) starved by the
# CLAUDE_TIMEOUT: the router exits non-zero with the PR done-but-UNMERGED.
# pr_has_actionable_work() returns false for that state (0 unresolved comments,
# 0 failing builds), so the heartbeat — the ONLY re-queuer — never re-dispatches it
# and the PR sits unmerged indefinitely (observed live: #1384 had to be merged by
# hand). This probe recognizes that state so the merge step gets retried.
#
# It is deliberately conservative — every gate below prevents a re-dispatch LOOP,
# the heartbeat's historical failure mode (cf. the #1376 "Require a merge strategy"
# loop guarded above). The circuit breaker in the dispatch loop is the final backstop.
pr_is_ready_but_unmerged() {
  local pr_id="$1" pr_json="$2"

  # Gates 1–3 are three independent "not-ready" booleans. Compute all three in a
  # SINGLE jq pass (previously four separate echo|jq forks) that returns one token.
  # The [no-auto] test mirrors pr_router.sh's LENIENT case-insensitive substring
  # match EXACTLY — combined tags like "[SPEC][no-auto]" must fire — but runs inside
  # jq via ascii_downcase|contains over title+description (≡ printf '%s\n%s' | grep -qi).
  # A stricter match here would disagree with the router and merge a PR it would not.
  #   no-auto → bot fixes/rebases but never casts the merge vote, so green+resolved+
  #             unmerged is its NORMAL terminal state; re-dispatch would loop forever.
  #   draft   → intentionally not-ready; never push it toward merge.
  #   armed   → auto-complete already set; ADO merges on its own, nothing to recover.
  # jq-failure backstop: if jq itself fails (bad binary, OOM, malformed $pr_json),
  # ready_signal falls back to "" and Gates 1–3 are bypassed together. This is NOT a
  # regression — the previous four-fork version failed the same way on the same bad
  # $pr_json — and it is safe because Gate 4 below is the real backstop: it re-derives
  # project_id (with the empty-$ADO_PROJECT not-ready guard) and requires ≥1 Build
  # policy ALL-approved before any re-dispatch, so an unparseable payload still cannot
  # push a PR toward merge.
  local ready_signal
  ready_signal=$(echo "$pr_json" | jq -r '
    if (((.title // "") + "\n" + (.description // "")) | ascii_downcase | contains("[no-auto]")) then "no-auto"
    elif (.isDraft // false) then "draft"
    elif (.autoCompleteSetBy != null) then "armed"
    else "ready"
    end' 2>/dev/null) || ready_signal=""
  case "$ready_signal" in
    no-auto|draft|armed) return 1 ;;
  esac

  # Gate 4 — require the Build policy to be APPROVED (green), not merely "not failing".
  # While a build is queued/running we must WAIT, not dispatch — otherwise a PR whose
  # build is still in flight would be re-queued on every cycle. Require ≥1 Build policy
  # and ALL Build policies approved.
  local project_id
  project_id=$(echo "$pr_json" | jq -r '.repository.project.id // empty' 2>/dev/null)
  if [ -z "$project_id" ]; then
    project_id="$ADO_PROJECT"
    if [ -z "$project_id" ]; then
      # Both the PR payload AND $ADO_PROJECT are empty → the policy URL would be
      # malformed (…/CodeReviewId//${pr_id}). Treat as not-ready rather than fire a
      # bad request; a later cycle with a well-formed payload can still recover it.
      log "⚠️  PR #${pr_id}: cannot resolve project id (PR payload and \$ADO_PROJECT both empty) — treating as not-ready"
      return 1
    fi
    log "⚠️  PR #${pr_id}: PR payload missing project id — falling back to \$ADO_PROJECT"
  fi
  local policy_url="${ADO_BASE}/policy/evaluations?artifactId=$(printf '%s' "vstfs:///CodeReview/CodeReviewId/${project_id}/${pr_id}" | jq -sRr @uri)&api-version=7.1-preview"
  local policy_evals
  policy_evals=$(ado_api_call "$policy_url" 2>/dev/null) || return 1

  local build_total build_approved
  build_total=$(echo "$policy_evals" | jq --arg bpt "$BUILD_POLICY_TYPE_ID" '[.value[]? | select(.configuration.type.id == $bpt)] | length' 2>/dev/null || echo "0")
  build_approved=$(echo "$policy_evals" | jq --arg bpt "$BUILD_POLICY_TYPE_ID" '[.value[]? | select(.configuration.type.id == $bpt and .status == "approved")] | length' 2>/dev/null || echo "0")
  [ "$build_total" -gt 0 ] && [ "$build_total" -eq "$build_approved" ]
}

# Build a synthetic webhook payload for a PR
build_synthetic_payload() {
  local pr_json="$1"
  jq -n --argjson pr "$pr_json" '{
    eventType: "ms.vss-code.git-pullrequest-comment-event",
    resource: {
      pullRequest: $pr,
      comment: {content: "heartbeat-recovery"}
    }
  }'
}

# Main heartbeat loop
REPO_ID=""
log "🫀 Heartbeat starting (interval: ${HEARTBEAT_INTERVAL_SECS}s)"

while true; do
  sleep "$HEARTBEAT_INTERVAL_SECS"

  # Lazy-resolve repo ID
  if [ -z "$REPO_ID" ]; then
    REPO_ID=$(get_repo_id) || { log "⚠️ Cannot resolve repo ID, skipping cycle"; continue; }
  fi

  # Fetch active PRs
  local_prs=$(ado_api_call "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests?searchCriteria.status=active&api-version=7.1" 2>/dev/null) || continue
  pr_count=$(echo "$local_prs" | jq '.count // (.value | length) // 0' 2>/dev/null || echo "0")

  if [ "$pr_count" = "0" ]; then
    continue  # No active PRs
  fi

  log "🫀 Checking $pr_count active PR(s) for orphaned work..."
  recovered=0

  while IFS= read -r pr_json; do
    local_pr_id=$(echo "$pr_json" | jq -r '.pullRequestId')
    [ -z "$local_pr_id" ] && continue

    # Skip if PR is already locked locally BY A LIVE HOLDER. A bare `-d` test
    # also matches dead-PID locks orphaned by an OOM/SIGKILL (cleanup() never
    # ran), which used to make the PR "appear to wait" forever — the heartbeat
    # is its only re-queuer, and it was skipping on a tombstone. Probe the
    # holder PID: only a live process means "someone is working it".
    if [ -d "$STATE_DIR/pr-${local_pr_id}.lock" ]; then
      local_lock_pid=$(sed -n '2p' "$STATE_DIR/pr-${local_pr_id}.lock/pid" 2>/dev/null || echo 0)
      if [ "$local_lock_pid" -gt 0 ] 2>/dev/null && kill -0 "$local_lock_pid" 2>/dev/null; then
        continue  # live holder — genuinely being processed
      fi
      # Dead holder: leave the lock for pr_router.sh to reclaim atomically on
      # dispatch (it owns lock lifecycle); do NOT skip — fall through to re-queue.
    fi

    # Concurrency stand-down — never re-dispatch a PR a human/agent is driving.
    # Mirrors the router's earliest gate (Tier 1 [no-bot], Tier 2 *-wip): the
    # router would bail on these immediately anyway, but skipping HERE avoids
    # accruing a pointless deferred entry that just spawns a router to no-op.
    #   Tier 2 — *-wip source branch (zero API cost, from the PR list payload).
    local_src=$(echo "$pr_json" | jq -r '.sourceRefName // ""' 2>/dev/null)
    local_src="${local_src#refs/heads/}"
    PR_BOT_WIP_SUFFIX="${PR_BOT_WIP_SUFFIX:--wip}"
    if [ -n "$PR_BOT_WIP_SUFFIX" ] && [ -n "$local_src" ] && \
       [ "$local_src" != "${local_src%"$PR_BOT_WIP_SUFFIX"}" ]; then
      continue  # human WIP scratch branch — bot stands down
    fi
    #   Tier 1 — [no-bot] directive in title/description (already in the PR list payload).
    local_title=$(echo "$pr_json" | jq -r '.title // ""' 2>/dev/null)
    local_desc=$(echo "$pr_json" | jq -r '.description // ""' 2>/dev/null)
    if pr_text_has_directive "$(printf '%s\n%s' "$local_title" "$local_desc")" "no-bot"; then
      continue  # human driving — bot stands down
    fi

    # Skip if active lease exists
    if pr_has_active_lease "$local_pr_id" "$REPO_ID"; then
      continue
    fi

    # Check if there's actionable work. Two independent triggers:
    #   (a) unresolved comments or failing builds — the original re-queue reason; or
    #   (b) "ready but unmerged" — all threads resolved + builds green, but the merge
    #       vote was never cast (its router run was starved by CLAUDE_TIMEOUT). Without
    #       (b) such a PR is invisible to recovery and sits unmerged forever (#1384).
    # Both fall through to the SAME circuit-breaker gate below, so neither can loop
    # beyond the breaker's backoff.
    if ! pr_has_actionable_work "$local_pr_id" "$REPO_ID"; then
      if pr_is_ready_but_unmerged "$local_pr_id" "$pr_json"; then
        log "🫀 PR #${local_pr_id} is ready-but-unmerged (green + resolved, no merge vote) — re-dispatching merge step"
      else
        continue
      fi
    fi

    # Circuit breaker: if this PR keeps crashing on the same head commit, don't
    # re-queue it while its backoff window is open. This is the primary stop for
    # the crash loop — the heartbeat is what re-queues failing PRs every cycle.
    # A new commit (different SHA) resets the breaker automatically.
    local_head=$(echo "$pr_json" | jq -r '.lastMergeSourceCommit.commitId // empty' 2>/dev/null)
    if [ -n "$local_head" ] && circuit_is_open "$local_pr_id" "$local_head"; then
      log "🚦 Circuit open for #${local_pr_id} on ${local_head:0:8} (retry in ${CIRCUIT_RETRY_IN}s), skipping re-queue"
      continue
    fi

    log "🫀 Found orphaned PR #${local_pr_id} with actionable work, dispatching..."

    # Write synthetic payload to the deferred queue so the main loop picks it up
    # on its next drain cycle (runs on reconnect and periodically).
    # DEDUP: key the file on the PR id ALONE (no timestamp). Previously every
    # cycle appended pr-<id>-<epoch>.json, so a PR that stayed orphaned across N
    # heartbeats accrued N duplicate queue entries (observed: 5x #1343, 4x #1360)
    # that each spawned a redundant router. A stable name means at most one
    # pending entry per PR; subsequent heartbeat cycles are no-ops while it is
    # still queued.
    local_defer_dir="$STATE_DIR/deferred"
    mkdir -p "$local_defer_dir"
    local_defer_file="$local_defer_dir/pr-${local_pr_id}.json"
    if [ -f "$local_defer_file" ]; then
      continue  # already queued for this PR — don't accrue duplicates
    fi
    local_payload=$(build_synthetic_payload "$pr_json")
    echo "$local_payload" > "$local_defer_file"
    recovered=$((recovered + 1))
  done < <(echo "$local_prs" | jq -c '.value[]' 2>/dev/null)

  [ "$recovered" -gt 0 ] && log "🫀 Queued $recovered orphaned PR(s) for processing"
done
