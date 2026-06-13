#!/usr/bin/env bash
# pr_policies.sh — PR Risk Classification, Approval & Auto-Complete
# Provides functions for risk classification via Claude, policy evaluation,
# auto-approval, build requeue, and auto-complete with squash merge.
#
# Required: ado_api_call, ADO_BASE, ADO_ORG, ADO_PROJECT, log()
#
# Key constraints:
# - Auto-complete requires ADO Engineering Contributors approval
# - Bot approves as its own identity
# - HIGH risk = no approve, no complete
# - Risk classification via Claude small/fast model on PR diffs

# Classify PR risk level using Claude.
# Usage: classify_pr_risk <pr_id> <repo_id> <work_dir>
# Outputs: JSON {"risk":"low|medium|high","reasoning":"..."}
classify_pr_risk() {
  local pr_id="$1"
  local repo_id="$2"
  local work_dir="$3"

  # Get commit diff for risk assessment
  local diff_content=""
  if [ -d "$work_dir" ]; then
    diff_content=$(git -C "$work_dir" diff "origin/main...HEAD" --stat 2>/dev/null | tail -30)
    # Also get a summary of actual changes (first 5000 chars)
    local full_diff
    full_diff=$(git -C "$work_dir" diff "origin/main...HEAD" 2>/dev/null | head -c 5000)
    diff_content="${diff_content}

${full_diff}"
  fi

  local prompt
  prompt="Classify the risk of this PR. Respond in JSON only, no markdown fences.

Risk levels:
- HIGH: breaking API changes, business logic causing unexpected behavior, broad system integration impact, security-sensitive changes
- LOW: docs, config, test-only, dependency bumps, formatting, comments
- MEDIUM: everything else

PR diff summary:
${diff_content}

Respond: {\"risk\":\"low|medium|high\",\"reasoning\":\"one sentence\"}"

  local result
  if command -v claude >/dev/null 2>&1; then
    result=$(timeout 120 claude --print --output-format text -p "$prompt" 2>/dev/null) || true
  fi

  if [ -z "$result" ]; then
    # Claude unavailable — require manual approval
    echo '{"risk":"unknown","reasoning":"Claude unavailable, requiring manual approval"}'
    return 0
  fi

  # Extract JSON from response (Claude may add text around it).
  # Use ERE (-oE), NOT PCRE (-oP): macOS/BSD grep has no -P, so under the bot's
  # launchd PATH (which resolves grep to /usr/bin/grep, not a gnubin GNU grep) -P
  # errors `invalid option -- P`, leaving json_result empty → risk ALWAYS "unknown"
  # → the classifier silently fail-closes on every PR (observed live on the macOS
  # node). `\{[^}]+\}` is portable ERE and matches the flat {"risk":...,"reasoning":...}
  # shape identically to the old -P pattern.
  local json_result
  json_result=$(echo "$result" | grep -oE '\{[^}]+\}' | head -1 2>/dev/null) || true
  if [ -n "$json_result" ] && echo "$json_result" | jq -e '.risk' >/dev/null 2>&1; then
    echo "$json_result"
  else
    echo '{"risk":"unknown","reasoning":"Could not parse Claude response, requiring manual approval"}'
  fi
}

# Get policy evaluations for a PR.
# Usage: get_policy_evaluations <pr_id> <project_id>
# Outputs: raw policy evaluations JSON
get_policy_evaluations() {
  local pr_id="$1"
  local project_id="$2"

  local url="${ADO_BASE}/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/${project_id}/${pr_id}&api-version=7.1"
  ado_api_call "$url" 2>/dev/null || echo '{"value":[]}'
}

# Detect policy issues from evaluations.
# Usage: detect_policy_issues <policy_evals_json>
# Outputs: JSON array of issues [{type, name, buildId}]
detect_policy_issues() {
  local evals="$1"

  echo "$evals" | jq -r '
    [.value[]
     | select(.status == "rejected" or .status == "broken" or .status == "queued" or .status == "running")
     | {
         type: (if .status == "rejected" then "failed"
                elif .status == "broken" then "expired"
                elif .status == "queued" or .status == "running" then "pending"
                else .status end),
         name: (.configuration.settings.displayName // .configuration.type.displayName // "unknown"),
         status: .status,
         buildId: (.context.buildId // null)
       }
    ]' 2>/dev/null || echo "[]"
}

# Auto-approve a PR (vote=10 = Approved).
# Only for LOW/MEDIUM risk. Skips for HIGH.
# Usage: auto_approve_pr <pr_id> <repo_id> <risk_level> [skip_auto]
# Returns: 0 on success, 1 on failure/skip
auto_approve_pr() {
  local pr_id="$1"
  local repo_id="$2"
  local risk_level="$3"
  local skip_auto="${4:-0}"

  # [no-auto] opt-out — disable auto-approve while leaving comment-fixing/rebasing intact.
  if [ "$skip_auto" = "1" ]; then
    log "⏸️  [no-auto] set — skipping auto-approve for PR #${pr_id}"
    return 1
  fi

  if [ "$risk_level" = "high" ] || [ "$risk_level" = "unknown" ]; then
    log "⚠️  ${risk_level^^} risk — skipping auto-approve for PR # ${pr_id}"
    return 1
  fi

  log "👍 Auto-approving PR #${pr_id} (risk: ${risk_level})..."

  # Get the bot's identity ID from the PR (we need reviewer ID)
  # Use "me" endpoint to get current user's ID
  local me_response
  me_response=$(ado_api_call "https://dev.azure.com/${ADO_ORG}/_apis/connectionData" 2>/dev/null) || true
  local reviewer_id
  reviewer_id=$(echo "$me_response" | jq -r '.authenticatedUser.id // empty' 2>/dev/null)

  if [ -z "$reviewer_id" ]; then
    log "⚠️  Could not determine bot identity for approval"
    return 1
  fi

  local vote_body='{"vote":10}'
  local vote_url="${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/reviewers/${reviewer_id}?api-version=7.1"

  if ado_api_call "$vote_url" "PUT" "$vote_body" >/dev/null 2>&1; then
    log "✅ PR #${pr_id} approved (vote=10)"
    return 0
  else
    log "⚠️  Failed to approve PR #${pr_id}"
    return 1
  fi
}

# Requeue a build for a PR.
# Usage: requeue_build <build_definition_id> <source_branch> <pr_id>
# Returns: build ID on success, empty on failure
requeue_build() {
  local definition_id="$1"
  local source_branch="$2"
  local pr_id="$3"

  local body
  body=$(jq -n --argjson defId "$definition_id" --arg branch "refs/heads/$source_branch" \
    '{definition:{id:$defId},sourceBranch:$branch,reason:"userCreated"}')

  local response
  response=$(ado_api_call "${ADO_BASE}/build/builds?api-version=7.1" "POST" "$body" 2>/dev/null) || return 1

  local build_id
  build_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)
  echo "$build_id"
}

# Poll build completion with 30s intervals, 20min max.
# Usage: poll_build_completion <build_id>
# Returns: 0 if succeeded, 1 if failed/timeout
poll_build_completion() {
  local build_id="$1"
  local max_wait=1200  # 20 minutes
  local interval=30
  local elapsed=0

  while [ "$elapsed" -lt "$max_wait" ]; do
    local build_status
    build_status=$(ado_api_call "${ADO_BASE}/build/builds/${build_id}?api-version=7.1" 2>/dev/null) || true

    local status result
    status=$(echo "$build_status" | jq -r '.status // "unknown"' 2>/dev/null)
    result=$(echo "$build_status" | jq -r '.result // "none"' 2>/dev/null)

    if [ "$status" = "completed" ]; then
      if [ "$result" = "succeeded" ]; then
        log "✅ Build #${build_id} succeeded"
        return 0
      else
        log "❌ Build #${build_id} completed with result: $result"
        return 1
      fi
    fi

    log "⏳ Build #${build_id} status: $status (${elapsed}s elapsed)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log "⏰ Build #${build_id} timed out after ${max_wait}s"
  return 1
}

# Auto-complete a PR with squash merge.
# Only for LOW/MEDIUM risk + all policies pass.
# Usage: auto_complete_pr <pr_id> <repo_id> <risk_level> [skip_auto]
# Returns: 0 on success, 1 on failure/skip
auto_complete_pr() {
  local pr_id="$1"
  local repo_id="$2"
  local risk_level="$3"
  local skip_auto="${4:-0}"

  # [no-auto] opt-out — disable auto-complete; a human must complete the PR.
  if [ "$skip_auto" = "1" ]; then
    log "⏸️  [no-auto] set — skipping auto-complete for PR #${pr_id}"
    return 1
  fi

  if [ "$risk_level" = "high" ]; then
    log "⚠️  HIGH risk — skipping auto-complete for PR #${pr_id}"
    return 1
  fi

  # Unresolved-comment gate (the #1389 regression: the PR auto-completed while three
  # review threads were still active). Auto-complete must NEVER arm while a human/
  # reviewer thread is unresolved — otherwise ADO merges out from under an open
  # conversation. We count active threads with the SAME canonical filter the router
  # and heartbeat use for "actionable work" (pr_router.sh TOTAL_UNRESOLVED /
  # pr_heartbeat.sh pr_has_actionable_work), so the three gates agree exactly:
  #   - status == "active" or null  → unresolved (the bot's own status/lease/risk
  #     threads are posted status:4 = closed, so they are excluded automatically);
  #   - exclude VoteUpdate system threads (an approval vote is not a conversation);
  #   - require ≥1 non-system comment (ignore pure system/policy threads).
  # FAIL CLOSED: if the threads API call fails we cannot prove the PR is clean, so we
  # decline to auto-complete rather than risk merging over an open thread.
  #
  # TOCTOU: there is an inherent (narrow) race between this unresolved-comment check
  # and the auto-complete PATCH below — a reviewer can open a new thread in that
  # window. We accept it: the worst case (auto-complete arms just as a brand-new
  # thread appears) is no worse than the pre-gate status quo, and ADO branch policy
  # still blocks the actual merge while a required reviewer/policy is pending. The
  # gate closes the common case (threads already active when the gate runs).
  local threads_json
  threads_json=$(ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1" 2>/dev/null) || {
    log "⚠️  Could not fetch threads for PR #${pr_id} — declining auto-complete (fail-closed)"
    return 1
  }
  local unresolved_count
  # Note the `?` on BOTH `.value[]?` and `.comments[]?`: a thread object with a
  # missing/null `comments` field would otherwise make the inner iterator raise and
  # cascade-fail the whole expression (masking a normal-path shape as the error path).
  # `.comments[]?` yields nothing for such threads, consistent with the `.value[]?`
  # guard, so the count stays correct instead of falling through to "unknown".
  unresolved_count=$(echo "$threads_json" | jq '
    [.value[]?
     | select(.status == "active" or .status == null)
     | select(.properties.CodeReviewThreadType.["$value"] != "VoteUpdate")
     | select([.comments[]? | select(.commentType != "system")] | length > 0)
    ] | length' 2>/dev/null || echo "unknown")
  if [ "$unresolved_count" != "0" ]; then
    log "💬 PR #${pr_id} has ${unresolved_count} unresolved comment thread(s) — skipping auto-complete until resolved"
    return 1
  fi

  # Get the bot's identity for the auto-complete-set-by field
  local me_response
  me_response=$(ado_api_call "https://dev.azure.com/${ADO_ORG}/_apis/connectionData" 2>/dev/null) || true
  local identity_id
  identity_id=$(echo "$me_response" | jq -r '.authenticatedUser.id // empty' 2>/dev/null)

  if [ -z "$identity_id" ]; then
    log "⚠️  Could not determine bot identity for auto-complete"
    return 1
  fi

  log "🏁 Setting auto-complete on PR #${pr_id} (squash merge, delete source branch)..."

  local body
  body=$(jq -n --arg id "$identity_id" '{
    autoCompleteSetBy: {id: $id},
    completionOptions: {
      mergeStrategy: "squash",
      deleteSourceBranch: true,
      transitionWorkItems: true,
      mergeCommitMessage: ""
    }
  }')

  local pr_url="${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}?api-version=7.1"
  if ado_api_call "$pr_url" "PATCH" "$body" >/dev/null 2>&1; then
    log "✅ Auto-complete set on PR #${pr_id}"
    return 0
  else
    log "⚠️  Failed to set auto-complete on PR #${pr_id}"
    return 1
  fi
}

# Post a transparency comment with risk assessment.
# Usage: post_risk_assessment <pr_id> <repo_id> <risk_json> <approved> <auto_completed> [skip_auto]
post_risk_assessment() {
  local pr_id="$1"
  local repo_id="$2"
  local risk_json="$3"
  local approved="$4"
  local auto_completed="$5"
  local skip_auto="${6:-0}"

  local risk_level reasoning
  risk_level=$(echo "$risk_json" | jq -r '.risk // "unknown"' 2>/dev/null)
  reasoning=$(echo "$risk_json" | jq -r '.reasoning // "N/A"' 2>/dev/null)

  # Normalize case: Claude may return "LOW"/"Low"/"low". The case statement below
  # (and the "high" comparison further down) match lowercase only, so without this an
  # uppercase risk like "LOW" would miss its arm and hit the *) fallthrough instead
  # of 🟢. Native lowercasing, matching the ${risk_level^^} expansion used just below.
  risk_level="${risk_level,,}"

  local risk_emoji
  case "$risk_level" in
    low)     risk_emoji="🟢" ;;
    medium)  risk_emoji="🟡" ;;
    high)    risk_emoji="🔴" ;;
    # "unknown" (classifier unavailable/unparseable) or any novel value: fail-closed to 🔴
    # so garbage/empty/novel values never look benign. The log line makes these visible
    # without changing the posture.
    *)       risk_emoji="🔴"
             log "⚠️  Unknown risk level '${risk_level}' for PR #${pr_id} — defaulting to 🔴 (fail-closed)" ;;
  esac

  local actions=""
  [ "$approved" = "true" ] && actions="${actions}✅ Auto-approved | "
  [ "$auto_completed" = "true" ] && actions="${actions}✅ Auto-complete set | "
  [ "$approved" = "false" ] && [ "$risk_level" = "high" ] && actions="${actions}❌ Approval withheld (HIGH risk) | "
  actions="${actions%| }"

  # When [no-auto] is set, surface a one-line notice that a human must approve & complete.
  local no_auto_note=""
  if [ "$skip_auto" = "1" ]; then
    no_auto_note="
⏸️ Auto-merge disabled via \`[no-auto]\` — human must approve & complete."
  fi

  local comment_content
  comment_content="${risk_emoji} **Left Jab Bot Risk Assessment**: **${risk_level^^}**

**Reasoning:** ${reasoning}

**Actions:** ${actions}${no_auto_note}

<!-- pr-bot-state:risk-assessed -->"

  local body
  body=$(jq -n --arg content "$comment_content" '{comments:[{parentCommentId:0,content:$content,commentType:1}],status:4}')
  ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1" "POST" "$body" >/dev/null 2>&1 || \
    log "⚠️  Failed to post risk assessment comment"
}

# Abandon a PR with a reason comment.
# Usage: abandon_pr <pr_id> <repo_id> <reason>
abandon_pr() {
  local pr_id="$1"
  local repo_id="$2"
  local reason="$3"

  local comment_body
  comment_body=$(jq -n --arg reason "$reason" \
    '{comments:[{parentCommentId:0,content:("🤖 **Left Jab Bot**: Abandoning this PR.\n\n**Reason:** " + $reason + "\n\n<!-- pr-bot-state:abandoned -->"),commentType:1}],status:4}')
  ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1" "POST" "$comment_body" >/dev/null 2>&1 || true

  local abandon_body='{"status":"abandoned"}'
  if ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}?api-version=7.1" "PATCH" "$abandon_body" >/dev/null 2>&1; then
    log "✅ PR #${pr_id} abandoned: ${reason}"
    return 0
  else
    log "❌ Failed to abandon PR #${pr_id}"
    return 1
  fi
}

# Requeue expired or stale build policy evaluations.
# ADO marks policy evaluations as "queued" even after the build completes;
# if no new push triggers a re-evaluation, they sit stale forever.
# This function re-evaluates each build policy via the ADO policy API.
# Usage: requeue_expired_policies <pr_id> <project_id> <policy_evals_json>
requeue_expired_policies() {
  local pr_id="$1"
  local project_id="$2"
  local evals="$3"

  # Find build policy evaluations that are queued/rejected/broken and have a completedDate
  # (meaning the build already ran but the policy wasn't re-evaluated after changes)
  local stale_evals
  stale_evals=$(echo "$evals" | jq -r '
    [.value[]
     | select(.configuration.type.displayName == "Build")
     | select(.status == "queued" or .status == "rejected" or .status == "broken")
     | {
         evaluationId: .evaluationId,
         name: (.configuration.settings.displayName // "unknown"),
         status: .status,
         buildId: (.context.buildId // null),
         definitionId: (.configuration.settings.buildDefinitionId // null)
       }
    ]' 2>/dev/null || echo "[]")

  local stale_count
  stale_count=$(echo "$stale_evals" | jq 'length' 2>/dev/null || echo "0")

  if [ "$stale_count" = "0" ]; then
    return 0
  fi

  log "🔄 Found $stale_count stale build policies, re-evaluating..."

  # Re-evaluate each stale policy via the ADO policy evaluation API
  # Uses process substitution to avoid subshell scope issues with pipe | while read
  while IFS= read -r eval_id; do
    if [ -z "$eval_id" ]; then continue; fi
    local eval_name
    eval_name=$(echo "$stale_evals" | jq -r --arg id "$eval_id" '.[] | select(.evaluationId == $id) | .name' 2>/dev/null)
    log "🔄 Re-evaluating policy: ${eval_name} (${eval_id})"
    # ADO policy re-evaluation PATCH requires a body but no specific fields — empty JSON is valid per the API docs
    local requeue_url="${ADO_BASE}/policy/evaluations/${eval_id}?api-version=7.1-preview"
    if ado_api_call "$requeue_url" "PATCH" '{}' >/dev/null 2>&1; then
      log "✅ Policy re-evaluation triggered: ${eval_name}"
    else
      log "⚠️  Failed to re-evaluate policy: ${eval_name}"
    fi
  done < <(echo "$stale_evals" | jq -r '.[] | .evaluationId' 2>/dev/null)
}

# Run the full policy gate after Claude's changes are pushed.
# Usage: run_policy_gate <pr_id> <repo_id> <project_id> <work_dir> [skip_auto]
run_policy_gate() {
  local pr_id="$1"
  local repo_id="$2"
  local project_id="$3"
  local work_dir="$4"
  local skip_auto="${5:-0}"

  log "🔍 Running policy gate for PR #${pr_id}..."

  # 1. Classify risk
  local risk_json
  risk_json=$(classify_pr_risk "$pr_id" "$repo_id" "$work_dir")
  local risk_level
  risk_level=$(echo "$risk_json" | jq -r '.risk // "medium"' 2>/dev/null)
  risk_level="${risk_level,,}"
  log "📊 Risk classification: ${risk_level}"

  # 2. Check policies
  local policy_evals
  policy_evals=$(get_policy_evaluations "$pr_id" "$project_id")
  local issues
  issues=$(detect_policy_issues "$policy_evals")
  local issue_count
  issue_count=$(echo "$issues" | jq 'length' 2>/dev/null || echo "0")

  local approved="false"
  local auto_completed="false"

  # 2b. Requeue stale/expired build policies before approval
  requeue_expired_policies "$pr_id" "$project_id" "$policy_evals"

  # 3. Auto-approve (LOW/MEDIUM only)
  if auto_approve_pr "$pr_id" "$repo_id" "$risk_level" "$skip_auto"; then
    approved="true"
  fi

  # 4. Wait for policies to settle, then try auto-complete
  if [ "$risk_level" != "high" ] && [ "$risk_level" != "unknown" ] && [ "$issue_count" = "0" ]; then
    # All policies passing — set auto-complete
    if auto_complete_pr "$pr_id" "$repo_id" "$risk_level" "$skip_auto"; then
      auto_completed="true"
    fi
  elif [ "$risk_level" != "high" ] && [ "$risk_level" != "unknown" ] && [ "$issue_count" -gt 0 ]; then
    # Policies still pending/failing — just set auto-complete and let ADO handle it
    log "⏳ $issue_count policy issues pending, setting auto-complete to trigger when ready..."
    if auto_complete_pr "$pr_id" "$repo_id" "$risk_level" "$skip_auto"; then
      auto_completed="true"
    fi
  fi

  # 5. Post transparency comment
  post_risk_assessment "$pr_id" "$repo_id" "$risk_json" "$approved" "$auto_completed" "$skip_auto"

  log "🏁 Policy gate complete (risk: ${risk_level}, approved: ${approved}, auto-complete: ${auto_completed}, skip_auto: ${skip_auto})"
}
