#!/usr/bin/env bash
# Untrusted events are hints. Only the configured, authenticated repository and PR
# supply action context. Source this module; it performs no work at load time.
# Requires jq, git, log(), and ado_api_request() (the unguarded GET transport).
# Public output variables are consumed by the sourcing router.
# shellcheck disable=SC2034

# jq -e reports only the last result for a stream of JSON documents. Require
# exactly one object before any extractor can emit multiple IDs into state paths.
pr_json_single_object() {
  printf '%s' "$1" | jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1
}

pr_event_valid() {
  pr_json_single_object "$1" || return 1
  printf '%s' "$1" | jq -e '
    def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
    def id: (type == "number" or type == "string") and (tostring | test("^[1-9][0-9]{0,9}$"));
    type == "object" and
    (.resource.pullRequest | type == "object") and
    (.resource.pullRequest.pullRequestId | id) and
    (.resource.pullRequest.repository.id | guid) and
    ((.notificationId // "") | (type == "number" or type == "string") and (tostring | test("^[A-Za-z0-9_.:-]{0,200}$"))) and
    ([.resource.pullRequest.repository.name, .resource.pullRequest.repository.project.name] |
      all(. == null or (type == "string" and length > 0 and (test("[[:cntrl:]]") | not)))) and
    (.resource.pullRequest.repository.project.id | . == null or guid)
  ' >/dev/null 2>&1
}

pr_text_has_directive() {
  local _text="$1" _marker="$2"
  printf '%s' "$_text" | grep -qiE "^[[:space:]]*([-*>][[:space:]]+)?\[${_marker}\]([[:space:]]|[:.]|\$)"
}

pr_guard_init() {
  local payload="$1" configured_repo repo_json
  pr_event_valid "$payload" || return 1
  # Config is trusted, but encode path segments so names cannot change the route.
  [[ "${ADO_ORG:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
  [ -n "${ADO_PROJECT:-}" ] && [ -n "${ADO_REPO:-}" ] || return 1
  ADO_BASE="https://dev.azure.com/${ADO_ORG}/$(printf '%s' "$ADO_PROJECT" | jq -sRr @uri)/_apis"
  configured_repo=$(printf '%s' "$ADO_REPO" | jq -sRr @uri)
  repo_json=$(ado_api_request "${ADO_BASE}/git/repositories/${configured_repo}?api-version=7.1") || return 1
  pr_json_single_object "$repo_json" || return 1
  printf '%s' "$repo_json" | jq -e --arg repo "$ADO_REPO" --arg project "$ADO_PROJECT" '
    def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
    (.id | guid) and (.project.id | guid) and
    (.name | type == "string" and length > 0) and (.project.name | type == "string" and length > 0) and
    ((.id | ascii_downcase) == ($repo | ascii_downcase) or (.name | ascii_downcase) == ($repo | ascii_downcase)) and
    ((.project.id | ascii_downcase) == ($project | ascii_downcase) or (.project.name | ascii_downcase) == ($project | ascii_downcase))
  ' >/dev/null 2>&1 || return 1
  REPO_ID=$(printf '%s' "$repo_json" | jq -r '.id | ascii_downcase')
  REPO_NAME=$(printf '%s' "$repo_json" | jq -r '.name')
  PROJECT_ID=$(printf '%s' "$repo_json" | jq -r '.project.id | ascii_downcase')
  PR_GUARD_REPO_JSON="$repo_json"
  printf '%s' "$payload" | jq -e --argjson repo "$repo_json" '
    .resource.pullRequest.repository |
    (.id | ascii_downcase) == ($repo.id | ascii_downcase) and
    (.name == null or (.name | ascii_downcase) == ($repo.name | ascii_downcase)) and
    (.project.id == null or (.project.id | ascii_downcase) == ($repo.project.id | ascii_downcase)) and
    (.project.name == null or (.project.name | ascii_downcase) == ($repo.project.name | ascii_downcase))
  ' >/dev/null 2>&1 || return 1
  PR_ID=$(printf '%s' "$payload" | jq -r '.resource.pullRequest.pullRequestId | tostring')
  PR_GUARD_SOURCE_REF=""
  PR_GUARD_TARGET_REF=""
  pr_guard_refresh
}

# Returns 0: current active PR; 2: intentional standdown; 75: changed source/target
# or stale expected head; 1: invalid/unavailable context. Flags are reset on EVERY
# read, including failures, so stale acceptance can never survive a failed refresh.
pr_guard_refresh() {
  local expected_head="${1:-}" details source_ref target_ref title description
  SKIP_AUTO=1
  RISK_OVERRIDE=0
  details=$(ado_api_request "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}?api-version=7.1") || return 1
  pr_json_single_object "$details" || return 1
  printf '%s' "$details" | jq -e --arg pr "$PR_ID" --arg repo "$REPO_ID" --arg project "$PROJECT_ID" '
    (.pullRequestId | tostring) == $pr and
    (.repository.id | ascii_downcase) == $repo and
    (.repository.project.id | ascii_downcase) == $project and
    (.title | type == "string") and (.description == null or (.description | type == "string")) and
    (.sourceRefName | type == "string" and startswith("refs/heads/")) and
    (.targetRefName | type == "string" and startswith("refs/heads/")) and
    (.lastMergeSourceCommit.commitId | type == "string" and test("^[0-9a-fA-F]{40}$")) and
    (.status == "active" or .status == 1 or .status == "completed" or .status == 3 or .status == "abandoned" or .status == 2) and
    (.forkSource == null)
  ' >/dev/null 2>&1 || return 1
  source_ref=$(printf '%s' "$details" | jq -r '.sourceRefName')
  target_ref=$(printf '%s' "$details" | jq -r '.targetRefName')
  git check-ref-format "$source_ref" >/dev/null 2>&1 || return 1
  git check-ref-format "$target_ref" >/dev/null 2>&1 || return 1
  # --branch rejects option-like branch names even if refs/heads/-name is a valid ref.
  git check-ref-format --branch "${source_ref#refs/heads/}" >/dev/null 2>&1 || return 1
  PR_DETAILS="$details"
  title=$(printf '%s' "$details" | jq -r '.title')
  description=$(printf '%s' "$details" | jq -r '.description // ""')
  PR_GUARD_HEAD=$(printf '%s' "$details" | jq -r '.lastMergeSourceCommit.commitId | ascii_downcase')
  if ! printf '%s' "$details" | jq -e '.status == "active" or .status == 1' >/dev/null; then
    return 2
  fi
  if pr_text_has_directive "$(printf '%s\n%s' "$title" "$description")" no-bot; then
    return 2
  fi
  local wip_suffix="${PR_BOT_WIP_SUFFIX:--wip}"
  if [ -n "$wip_suffix" ] && [[ "${source_ref#refs/heads/}" == *"$wip_suffix" ]]; then
    return 2
  fi
  if { [ -n "${PR_GUARD_SOURCE_REF:-}" ] && [ "$source_ref" != "$PR_GUARD_SOURCE_REF" ]; } ||
     { [ -n "${PR_GUARD_TARGET_REF:-}" ] && [ "$target_ref" != "$PR_GUARD_TARGET_REF" ]; }; then
    return 75
  fi
  if [ -n "$expected_head" ] && [ "$expected_head" != "$PR_GUARD_HEAD" ]; then
    return 75
  fi
  PR_GUARD_SOURCE_REF="$source_ref"
  PR_GUARD_TARGET_REF="$target_ref"
  SOURCE_BRANCH="${source_ref#refs/heads/}"
  SKIP_AUTO=0
  if printf '%s\n%s' "$title" "$description" | grep -qiE '\[no-auto\]'; then SKIP_AUTO=1; fi
  if pr_text_has_directive "$title" risk-approved; then RISK_OVERRIDE=1; fi
  return 0
}

# Called in the router's main shell, not an `if` or `|| true` function context.
pr_guard_require() {
  local rc=0
  pr_guard_refresh "${1:-}" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) log "🤝 Authoritative PR state requests standdown"; exit 0 ;;
    75) log "🤝 PR source/target changed; yielding stale work"; exit 75 ;;
    *) log "❌ Cannot validate authoritative PR context; aborting"; exit 1 ;;
  esac
}

pr_guard_origin_matches() {
  local fetch_urls push_urls destination
  # get-url expands insteadOf/pushInsteadOf; --all includes every push target.
  # A matching fetch URL alone says nothing about a separately configured pushurl.
  fetch_urls=$(git -C "$1" remote get-url --all origin) || return 1
  push_urls=$(git -C "$1" remote get-url --push --all origin) || return 1
  [ -n "$fetch_urls" ] && [ -n "$push_urls" ] || return 1
  while IFS= read -r destination; do
    [ -n "$destination" ] || return 1
    printf '%s' "$PR_GUARD_REPO_JSON" | jq -e --arg origin "$destination" '
      def normalize: sub("^https://[^/@]+@"; "https://") | sub("/$"; "") | ascii_downcase;
      [$origin | normalize] as $local |
      [.remoteUrl, .sshUrl] | any(type == "string" and length > 0 and ([normalize] == $local))
    ' >/dev/null 2>&1 || return 1
  done <<< "$(printf '%s\n%s' "$fetch_urls" "$push_urls")"
  return 0
}

# Router-issued API mutations recheck the PR, including writes inside helper
# functions and command substitutions. Read-to-write races still exist; this does
# not sandbox writes issued independently by an already-running model session.
pr_guard_check_write() {
  local url="$1" method="${2:-GET}"
  if [ "$method" != GET ]; then
    # Cleanup must release only this run's already-held lease even after standdown.
    if [ "${PR_GUARD_RELEASING_LEASE:-0}" = 1 ] && [ "$method" = PATCH ] &&
       [ -n "${LEASE_THREAD_ID:-}" ] && [ -n "${LEASE_COMMENT_ID:-}" ] &&
       [ "$url" = "${ADO_BASE}/git/repositories/${REPO_ID}/pullRequests/${PR_ID}/threads/${LEASE_THREAD_ID}/comments/${LEASE_COMMENT_ID}?api-version=7.1" ]; then
      return 0
    fi
    pr_guard_refresh "${PR_GUARD_POLICY_HEAD:-}" || return 1
    # The risk decision is bound to the classified head. Refresh markers just
    # before the actual vote/auto-complete request, not only before classification.
    if [[ "$url" == */reviewers/* ]] || [[ "${3:-}" == *'"autoCompleteSetBy"'* ]]; then
      [ "$SKIP_AUTO" = 0 ] || return 1
      case "${PR_GUARD_RISK_LEVEL:-unknown}" in
        low|medium) ;;
        high) [ "$RISK_OVERRIDE" = 1 ] || return 1 ;;
        *) return 1 ;;
      esac
    fi
  fi
  return 0
}

pr_guard_api_call() {
  pr_guard_check_write "$@" || return 1
  ado_api_request "$@"
}

# Local crash-record updates only. Both router publication and recovery removal
# use this lock; never hold it across HTTP. Keep the flock inode permanently.
pr_crash_state_update() (
  local file="$1" operation="$2" value="$3" state_fd attempt
  local lock="${file}.state.lock"
  [[ "${file##*/}" =~ ^pr-[1-9][0-9]{0,9}\.crashed$ ]] || return 1
  if command -v flock >/dev/null 2>&1; then
    exec {state_fd}<>"${file}.state.flock" || return 1
    flock -w 5 "$state_fd" || return 1
  else
    for ((attempt=0; attempt<100; attempt++)); do
      if mkdir "$lock" 2>/dev/null; then break; fi
      sleep 0.05
    done
    [ "$attempt" -lt 100 ] || return 1
    # Fail closed after SIGKILL: never reclaim an unknown directory owner.
    trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  fi
  [ ! -L "$file" ] || return 1
  case "$operation" in
    publish)
      # The caller created this same-directory temporary file with mktemp.
      [[ "$value" == "$file".pending.* ]] && [ -f "$value" ] && [ ! -L "$value" ] || return 1
      mv -f "$value" "$file"
      ;;
    remove)
      [ "$(cat "$file")" = "$value" ] || return 1
      rm -f "$file"
      ;;
    *) return 1 ;;
  esac
)

pr_crash_state_publish() {
  local file="$1" record="$2" pending
  pr_json_single_object "$record" || return 1
  pending=$(mktemp "${file}.pending.XXXXXX") || return 1
  # On failure keep the pending record for inspection, never expose partial JSON
  # at the live path or silently discard a newer crash during lock contention.
  if ! printf '%s\n' "$record" > "$pending" ||
     ! pr_crash_state_update "$file" publish "$pending"; then
    printf 'Crash record publication deferred; retained pending file: %s\n' "$pending" >&2
    return 1
  fi
}
