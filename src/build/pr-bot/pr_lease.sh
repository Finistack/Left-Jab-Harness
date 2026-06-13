#!/usr/bin/env bash
# pr_lease.sh — Distributed PR processing lease via ADO PR comments
# Uses a SINGLE persistent status thread per PR across all processing attempts.
# A single lease reply is reused with an iteration counter (no comment accumulation).
# Requires: ado_api_call(), ADO_BASE, REPO_ID, PR_ID, CLAUDE_TIMEOUT, log()

# Global lease state (set by acquire_pr_lease, used by release_pr_lease)
LEASE_THREAD_ID=""
LEASE_COMMENT_ID=""
EXISTING_LEASE_HOST=""

# Find the persistent status thread for this PR.
# Returns thread ID via stdout, or empty if not found.
# Expects PR_THREADS_JSON to be populated (or fetches it).
find_status_thread() {
  local pr_id="$1" repo_id="$2"
  local marker="<!-- pr-bot-status:PR-${pr_id} -->"

  # Use cached threads if available, otherwise fetch
  local threads_json="${PR_THREADS_JSON:-}"
  if [ -z "$threads_json" ]; then
    threads_json=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1") || {
      return 1
    }
    PR_THREADS_JSON="$threads_json"
  fi

  # Find thread whose first comment contains our marker
  echo "$threads_json" | jq -r --arg marker "$marker" '
    [.value[]
     | select(.comments[0].content // "" | contains($marker))
    ] | first // empty | .id // empty' 2>/dev/null
}

# Create the persistent status thread for this PR.
# Returns thread ID via stdout.
create_status_thread() {
  local pr_id="$1" repo_id="$2"
  local marker="<!-- pr-bot-status:PR-${pr_id} -->"
  local content
  content=$(printf '%s\n🤖 **Left Jab Bot Status** — automated processing log for PR # %s' "$marker" "$pr_id")

  local body
  body=$(jq -n --arg c "$content" '{comments:[{parentCommentId:0,content:$c,commentType:1}],status:4}')
  local response
  response=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1" "POST" "$body") || {
    return 1
  }

  echo "$response" | jq -r '.id // empty'
}

# Ensure the persistent status thread exists. Sets LEASE_THREAD_ID.
# Returns 0 on success, 1 on failure.
ensure_status_thread() {
  local pr_id="$1" repo_id="$2"

  local tid
  tid=$(find_status_thread "$pr_id" "$repo_id")
  if [ -n "$tid" ] && [ "$tid" != "null" ]; then
    LEASE_THREAD_ID="$tid"
    return 0
  fi

  # Create new status thread
  tid=$(create_status_thread "$pr_id" "$repo_id")
  if [ -n "$tid" ] && [ "$tid" != "null" ]; then
    LEASE_THREAD_ID="$tid"
    # Invalidate cached threads since we just created one
    PR_THREADS_JSON=""
    return 0
  fi

  log "⚠️  Failed to create status thread for PR #${pr_id}"
  return 1
}

# Check if an active (non-expired, non-done/failed) lease exists on this PR.
# Returns 0 if active lease found (caller should skip), 1 if no active lease.
# Sets EXISTING_LEASE_HOST on return 0 for logging.
# Stores threads JSON in PR_THREADS_JSON for downstream reuse.
check_pr_lease() {
  local pr_id="$1" repo_id="$2"
  local now
  now=$(date +%s)
  local grace=60  # clock skew tolerance

  local threads_json
  threads_json=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1") || {
    log "⚠️  Failed to fetch threads for lease check — skipping processing (fail-closed)"
    EXISTING_LEASE_HOST="unknown (API failure)"
    return 0  # fail-closed: don't process if we can't check lease
  }

  # Store for downstream reuse (avoids duplicate API call)
  PR_THREADS_JSON="$threads_json"

  local marker="<!-- pr-bot-status:PR-${pr_id} -->"

  # Find active lease: scan replies on the status thread for active lease comments
  local lease_info
  lease_info=$(echo "$threads_json" | jq -r --arg marker "$marker" --argjson now "$now" --argjson grace "$grace" '
    [.value[]
     | select(.comments[0].content // "" | contains($marker))
     | .comments[1:][]
     | .content // ""
     | capture("<!-- pr-bot-lease:(?<json>\\{[^}]+\\}) -->")
     | .json | fromjson
     | select(.expires + $grace > $now)
     | select(.status != "done" and .status != "failed")
    ] | sort_by(-.ts) | first // empty') 2>/dev/null

  # Also check legacy threads (non-status-thread lease comments) for backwards compat
  if [ -z "$lease_info" ]; then
    lease_info=$(echo "$threads_json" | jq -r --arg marker "$marker" --argjson now "$now" --argjson grace "$grace" '
      [.value[]
       | select(.comments[0].content // "" | contains($marker) | not)
       | select(.status != "closed" and .status != 4)
       | .comments[]
       | .content // ""
       | capture("<!-- pr-bot-lease:(?<json>\\{[^}]+\\}) -->")
       | .json | fromjson
       | select(.expires + $grace > $now)
       | select(.status != "done" and .status != "failed")
      ] | sort_by(-.ts) | first // empty') 2>/dev/null
  fi

  if [ -n "$lease_info" ]; then
    EXISTING_LEASE_HOST=$(echo "$lease_info" | jq -r '.host // "unknown"')
    local lease_pid this_host
    lease_pid=$(echo "$lease_info" | jq -r '.pid // empty')
    this_host=$(hostname -s 2>/dev/null || echo "unknown")
    # OOM/crash self-heal: a SIGKILL (e.g. cgroup OOM) tears down a router WITHOUT
    # running cleanup(), so its lease is never marked done/failed and stays
    # "active" for the full CLAUDE_TIMEOUT TTL (~30min) — making the PR appear to
    # wait while nobody processes it. If the lease is OURS (same host) and the
    # holder PID is dead, it's an orphan: treat it as reclaimable so we proceed to
    # re-acquire now. Cross-host leases are NEVER probed (we can't kill -0 a PID on
    # another machine), preserving distributed-lease safety.
    if [ "$EXISTING_LEASE_HOST" = "$this_host" ] && [ -n "$lease_pid" ] \
       && [ "$lease_pid" -gt 0 ] 2>/dev/null && ! kill -0 "$lease_pid" 2>/dev/null; then
      log "🧹 Reclaiming orphaned lease for #${pr_id} (our host ${this_host}, holder PID ${lease_pid} dead — likely OOM/crash)"
      return 1  # treat as no active lease → caller re-acquires
    fi
    # Guard against PID reuse: if the holder PID is alive but its start time
    # differs from what the lease recorded, the PID was recycled → orphaned lease.
    if [ "$EXISTING_LEASE_HOST" = "$this_host" ] && [ -n "$lease_pid" ] \
       && [ "$lease_pid" -gt 0 ] 2>/dev/null && kill -0 "$lease_pid" 2>/dev/null; then
      local lease_lstart recorded_lstart
      lease_lstart=$(ps -o lstart= -p "$lease_pid" 2>/dev/null | xargs) || lease_lstart=""
      recorded_lstart=$(echo "$lease_info" | jq -r '.lstart // empty' 2>/dev/null) || recorded_lstart=""
      if [ -n "$recorded_lstart" ] && [ -n "$lease_lstart" ] \
         && [ "$recorded_lstart" != "$lease_lstart" ]; then
        log "🧹 Reclaiming lease for #${pr_id} (PID ${lease_pid} recycled: lstart='${lease_lstart}' != recorded='${recorded_lstart}')"
        return 1  # PID reuse detected → treat as reclaimable
      fi
    fi
    return 0  # active lease exists
  fi
  return 1  # no active lease
}

# Find existing lease reply on the status thread.
# Returns "comment_id iteration" via stdout, or empty if none found.
find_lease_reply() {
  local pr_id="$1" repo_id="$2"
  local threads_json="${PR_THREADS_JSON:-}"
  [ -z "$threads_json" ] && return 1

  local marker="<!-- pr-bot-status:PR-${pr_id} -->"

  # Find the most recent lease reply (by comment ID, descending)
  echo "$threads_json" | jq -r --arg marker "$marker" '
    [.value[]
     | select(.comments[0].content // "" | contains($marker))
     | .comments[1:][]
     | select(.content // "" | contains("pr-bot-lease"))
     | { id: .id, content: .content }
    ] | sort_by(-.id) | first // empty
    | if . == "" or . == null then empty
      else
        .id as $id |
        (.content | capture("<!-- pr-bot-lease:(?<json>\\{[^}]+\\}) -->") | .json | fromjson | .iteration // 0) as $iter |
        "\($id) \($iter)"
      end' 2>/dev/null
}

# Acquire lease by creating or updating a SINGLE lease reply on the status thread.
# Reuses existing lease comment with an incremented iteration counter to avoid
# accumulating invisible comments on every processing run.
# Returns 0 on success (lease acquired), 1 on failure (race lost or API error).
# Sets LEASE_THREAD_ID, LEASE_COMMENT_ID on success.
acquire_pr_lease() {
  local pr_id="$1" repo_id="$2"
  local hostname
  hostname=$(hostname -s 2>/dev/null || echo "unknown")
  local now
  now=$(date +%s)
  local expires=$((now + ${CLAUDE_TIMEOUT:-1800}))

  # Ensure persistent status thread exists
  ensure_status_thread "$pr_id" "$repo_id" || {
    log "⚠️  Cannot acquire lease — no status thread"
    return 1
  }

  # Check for existing lease reply to reuse (avoids comment accumulation)
  local existing_reply iteration=0
  existing_reply=$(find_lease_reply "$pr_id" "$repo_id") || true

  if [ -n "$existing_reply" ]; then
    local existing_cid existing_iter
    existing_cid=$(echo "$existing_reply" | awk '{print $1}')
    existing_iter=$(echo "$existing_reply" | awk '{print $2}')
    existing_iter="${existing_iter:-0}"
    iteration=$((existing_iter + 1))

    # Update existing lease comment in place
    local lstart
    lstart=$(ps -o lstart= -p $$ 2>/dev/null | xargs) || lstart=""
    local lease_json
    lease_json=$(jq -cn --arg host "$hostname" --argjson pid $$ --argjson ts "$now" --argjson expires "$expires" --argjson iteration "$iteration" --arg lstart "$lstart" \
      '{host:$host,pid:$pid,ts:$ts,expires:$expires,iteration:$iteration,lstart:$lstart}')
    local content
    content=$(printf '<!-- pr-bot-lease:%s -->\n🤖 Processing on `%s` (PID %s) — iteration %d' "$lease_json" "$hostname" "$$" "$iteration")

    local body
    body=$(jq -n --arg c "$content" '{content:$c}')
    if ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads/${LEASE_THREAD_ID}/comments/${existing_cid}?api-version=7.1" "PATCH" "$body" >/dev/null 2>&1; then
      LEASE_COMMENT_ID="$existing_cid"
      log "🔒 Acquired PR lease for #${pr_id} (host: ${hostname}, iteration: ${iteration}, expires in ${CLAUDE_TIMEOUT:-1800}s)"
      return 0
    fi
    log "⚠️  Failed to update lease reply — falling back to new reply"
  fi

  # No existing lease reply (or update failed) — create one
  local lstart
  lstart=$(ps -o lstart= -p $$ 2>/dev/null | xargs) || lstart=""
  local lease_json
  lease_json=$(jq -cn --arg host "$hostname" --argjson pid $$ --argjson ts "$now" --argjson expires "$expires" --argjson iteration 0 --arg lstart "$lstart" \
    '{host:$host,pid:$pid,ts:$ts,expires:$expires,iteration:0,lstart:$lstart}')
  local content
  content=$(printf '<!-- pr-bot-lease:%s -->\n🤖 Processing on `%s` (PID %s) — iteration 0' "$lease_json" "$hostname" "$$")

  # Post reply on the status thread (parentCommentId=1 = reply to first comment)
  local body
  body=$(jq -n --arg c "$content" '{content:$c,parentCommentId:1,commentType:1}')
  local response
  response=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads/${LEASE_THREAD_ID}/comments?api-version=7.1" "POST" "$body") || {
    log "⚠️  Failed to post lease reply — proceeding without lease"
    return 1
  }

  LEASE_COMMENT_ID=$(echo "$response" | jq -r '.id')

  if [ -z "$LEASE_COMMENT_ID" ] || [ "$LEASE_COMMENT_ID" = "null" ]; then
    log "⚠️  Lease reply posted but no comment ID returned"
    LEASE_COMMENT_ID=""
    return 1
  fi

  # CAS: re-check for competing leases posted before ours
  sleep 1  # brief delay to let competing posts land
  local threads_json
  threads_json=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1") || {
    log "⚠️  CAS re-check failed — proceeding with lease (optimistic)"
    return 0
  }

  local marker="<!-- pr-bot-status:PR-${pr_id} -->"
  local earlier_lease
  earlier_lease=$(echo "$threads_json" | jq -r --arg marker "$marker" --argjson our_ts "$now" --argjson our_cid "$LEASE_COMMENT_ID" --argjson grace 60 '
    [.value[]
     | select(.comments[0].content // "" | contains($marker))
     | .comments[1:][]
     | select(.id != $our_cid)
     | .content // ""
     | capture("<!-- pr-bot-lease:(?<json>\\{[^}]+\\}) -->")
     | .json | fromjson
     | select(.status != "done" and .status != "failed")
     | select(.ts <= $our_ts)
     | select(.expires + $grace > $our_ts)
    ] | first // empty' 2>/dev/null)

  if [ -n "$earlier_lease" ]; then
    local winner_host
    winner_host=$(echo "$earlier_lease" | jq -r '.host // "unknown"')
    log "⏭️  Lost lease race — earlier acquisition by ${winner_host}"
    # Mark our lease as failed (best-effort)
    local failed_json
    failed_json=$(jq -cn --arg host "$hostname" --argjson pid $$ --argjson ts "$now" --arg status "failed" \
      '{host:$host,pid:$pid,ts:$ts,status:$status}')
    local failed_content
    failed_content=$(printf '<!-- pr-bot-lease:%s -->' "$failed_json")
    local failed_body
    failed_body=$(jq -n --arg c "$failed_content" '{content:$c}')
    ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads/${LEASE_THREAD_ID}/comments/${LEASE_COMMENT_ID}?api-version=7.1" \
      "PATCH" "$failed_body" >/dev/null 2>&1 || true
    LEASE_COMMENT_ID=""
    return 1
  fi

  log "🔒 Acquired PR lease for #${pr_id} (host: ${hostname}, iteration: 0, expires in ${CLAUDE_TIMEOUT:-1800}s)"
  return 0
}

# Update lease reply with final status. Best-effort — don't block cleanup.
# On success ("done"), silently update the reply to status:done.
# On failure, update the reply with a visible ⚠️ message.
# Usage: release_pr_lease "done" "pushed fixes"
#        release_pr_lease "failed" "exit code 1"
release_pr_lease() {
  local status="$1"
  local message="${2:-}"
  [ -z "$LEASE_THREAD_ID" ] && return 0
  [ -z "$LEASE_COMMENT_ID" ] && return 0

  local hostname
  hostname=$(hostname -s 2>/dev/null || echo "unknown")
  local now
  now=$(date +%s)

  local lease_json
  lease_json=$(jq -cn --arg host "$hostname" --argjson pid $$ --argjson ts "$now" --arg status "$status" \
    '{host:$host,pid:$pid,ts:$ts,status:$status}')

  if [ "$status" = "done" ]; then
    # Success — silently update reply to status:done (invisible, just metadata)
    local done_content
    done_content=$(printf '<!-- pr-bot-lease:%s -->' "$lease_json")
    local done_body
    done_body=$(jq -n --arg c "$done_content" '{content:$c}')
    ado_api_call "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}/threads/${LEASE_THREAD_ID}/comments/${LEASE_COMMENT_ID}?api-version=7.1" \
      "PATCH" "$done_body" >/dev/null 2>&1 || true
    return 0
  fi

  # Failure — update reply with visible ⚠️ message
  local content
  content=$(printf '<!-- pr-bot-lease:%s -->\n⚠️ **Left Jab Bot**: %s on `%s`%s' \
    "$lease_json" "$status" "$hostname" "${message:+ — $message}")
  local body
  body=$(jq -n --arg c "$content" '{content:$c}')
  ado_api_call "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}/threads/${LEASE_THREAD_ID}/comments/${LEASE_COMMENT_ID}?api-version=7.1" \
    "PATCH" "$body" >/dev/null 2>&1 || true
}
