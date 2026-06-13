#!/usr/bin/env bash
# pr_analysis.sh — PR Description Analysis & Conflict Resolution
# Provides functions for PR description analysis via Claude, merge conflict
# detection, auto-rebase, and conflict comment management.
#
# Required: ado_api_call, ADO_BASE, ADO_ORG, ADO_PROJECT, REPO_ID, log()

# Analyze PR description using Claude small/fast model.
# Extracts: changelog needed? breaking changes? migration needed?
# Usage: analyze_pr_description <pr_details_json> <work_dir>
# Outputs: JSON with analysis results
analyze_pr_description() {
  local pr_details="$1"
  local work_dir="$2"

  local pr_title pr_description
  pr_title=$(echo "$pr_details" | jq -r '.title // ""' 2>/dev/null)
  pr_description=$(echo "$pr_details" | jq -r '.description // ""' 2>/dev/null)

  # Get diff summary for context
  local diff_stat=""
  if [ -d "$work_dir" ]; then
    diff_stat=$(git -C "$work_dir" diff --stat "origin/main...HEAD" 2>/dev/null | tail -20)
  fi

  local prompt
  prompt="Analyze this PR and respond in JSON only (no markdown):
Title: ${pr_title}
Description: ${pr_description}
Files changed: ${diff_stat}

Return: {\"changelog_needed\": bool, \"breaking_changes\": bool, \"migration_needed\": bool, \"summary\": \"one-line summary\"}"

  local result
  if command -v claude >/dev/null 2>&1; then
    result=$(echo "$prompt" | timeout 60 claude --print --output-format text -p "$prompt" 2>/dev/null) || true
  fi

  if [ -z "$result" ]; then
    echo '{"changelog_needed":false,"breaking_changes":false,"migration_needed":false,"summary":"analysis unavailable"}'
    return 0
  fi

  # Try to extract JSON from response
  echo "$result" | jq '.' 2>/dev/null || echo '{"changelog_needed":false,"breaking_changes":false,"migration_needed":false,"summary":"parse error"}'
}

# Check for merge conflicts by performing a dry-run merge.
# Usage: check_merge_conflicts <work_dir> <source_branch>
# Returns: 0 if no conflicts, 1 if conflicts exist
# Outputs: list of conflicted files on stdout
check_merge_conflicts() {
  local work_dir="$1"
  local source_branch="$2"

  [ ! -d "$work_dir" ] && return 0

  # Fetch latest main
  git -C "$work_dir" fetch origin main 2>/dev/null || true

  # Try merge --no-commit --no-ff to detect conflicts without modifying worktree
  local merge_output
  if merge_output=$(git -C "$work_dir" merge-tree "$(git -C "$work_dir" merge-base origin/main HEAD)" HEAD origin/main 2>&1); then
    # No conflicts
    return 0
  fi

  # Extract conflict files
  echo "$merge_output" | grep -E '^(CONFLICT|Auto-merging)' 2>/dev/null || true
  return 1
}

# Attempt auto-rebase of a PR branch onto main.
# Usage: auto_rebase_pr <work_dir> <source_branch>
# Returns: 0 on success, 1 on failure (conflicts)
auto_rebase_pr() {
  local work_dir="$1"
  local source_branch="$2"

  [ ! -d "$work_dir" ] && return 1

  log "🔄 Attempting auto-rebase of ${source_branch} onto main..."
  git -C "$work_dir" fetch origin main 2>/dev/null || true

  if git -C "$work_dir" rebase origin/main 2>&1; then
    log "✅ Rebase successful"
    # Push with force-with-lease
    if git -C "$work_dir" push --force-with-lease origin HEAD:"refs/heads/${source_branch}" 2>&1; then
      log "✅ Force-push after rebase succeeded"
      return 0
    else
      log "❌ Force-push after rebase failed"
      git -C "$work_dir" rebase --abort 2>/dev/null || true
      return 1
    fi
  else
    log "❌ Rebase failed (conflicts), aborting..."
    git -C "$work_dir" rebase --abort 2>/dev/null || true
    return 1
  fi
}

# Post a comment on the PR listing conflict files and requesting resolution.
# Usage: post_conflict_comment <pr_id> <repo_id> <conflict_files>
post_conflict_comment() {
  local pr_id="$1"
  local repo_id="$2"
  local conflict_files="$3"

  local comment_content
  comment_content="⚠️ **Left Jab Bot**: Merge conflicts detected with \`main\`. Auto-rebase failed.

**Conflicting files:**
\`\`\`
${conflict_files}
\`\`\`

Please resolve the conflicts manually and push to the PR branch. The bot will resume processing once conflicts are resolved.

<!-- pr-bot-state:conflict -->"

  local body
  body=$(jq -n --arg content "$comment_content" '{comments:[{parentCommentId:0,content:$content,commentType:1}],status:1}')
  ado_api_call "${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/threads?api-version=7.1" "POST" "$body" >/dev/null 2>&1 || \
    log "⚠️  Failed to post conflict comment"
}

# Check if a conflict thread has been replied to (indicating manual resolution).
# Usage: check_conflict_reply <pr_id> <repo_id> <threads_json>
# Returns: 0 if conflict resolved (reply found or no conflict thread), 1 if still conflicted
check_conflict_reply() {
  local pr_id="$1"
  local repo_id="$2"
  local threads_json="$3"

  # Look for active conflict threads
  local conflict_thread
  conflict_thread=$(echo "$threads_json" | jq -r '
    [.value[]
     | select(.status == "active" or .status == null)
     | select(.comments[].content | test("pr-bot-state:conflict"))
     | {threadId: .id, commentCount: (.comments | length)}
    ] | first // empty' 2>/dev/null)

  if [ -z "$conflict_thread" ]; then
    return 0  # No conflict thread — not conflicted
  fi

  local comment_count
  comment_count=$(echo "$conflict_thread" | jq -r '.commentCount // 1' 2>/dev/null)

  if [ "$comment_count" -gt 1 ]; then
    log "✅ Conflict thread has replies — conflicts may be resolved"
    return 0
  fi

  log "⚠️  Conflict thread still active with no replies"
  return 1
}

# Run the full analysis phase before Claude invocation.
# Usage: run_pr_analysis <pr_id> <repo_id> <pr_details> <work_dir> <source_branch> <threads_json>
# Returns: 0 to continue, 1 to skip (unresolved conflicts)
run_pr_analysis() {
  local pr_id="$1"
  local repo_id="$2"
  local pr_details="$3"
  local work_dir="$4"
  local source_branch="$5"
  local threads_json="$6"

  # Check if there's an unresolved conflict thread
  if ! check_conflict_reply "$pr_id" "$repo_id" "$threads_json"; then
    # Verify if conflicts are actually resolved by trying merge again
    if check_merge_conflicts "$work_dir" "$source_branch" >/dev/null 2>&1; then
      log "✅ Conflicts appear resolved despite open thread"
    else
      log "⏭️  PR #${pr_id} has unresolved merge conflicts, skipping"
      return 1
    fi
  fi

  # Check for new merge conflicts
  local conflict_files conflict_exit=0
  conflict_files=$(check_merge_conflicts "$work_dir" "$source_branch" 2>/dev/null) || conflict_exit=$?
  if [ "$conflict_exit" -ne 0 ] && [ -n "$conflict_files" ]; then
    log "⚠️  Merge conflicts detected, attempting auto-rebase..."
    if ! auto_rebase_pr "$work_dir" "$source_branch"; then
      post_conflict_comment "$pr_id" "$repo_id" "$conflict_files"
      return 1
    fi
  fi

  return 0
}
