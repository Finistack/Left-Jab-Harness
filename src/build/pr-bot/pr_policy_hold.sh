#!/usr/bin/env bash
# Local recovery hint, never approval authority. Only heartbeat's merge-only
# recovery consults this; genuine events and actionable comments/builds bypass it.
# A successful HIGH-risk refusal is terminal for unchanged inputs, not a crash.
pr_policy_hold_key() {
  local pr="$1" policies="$2"
  jq -cSe --argjson policies "$policies" '
    select((.pullRequestId | type) == "number") |
    select((.repository.id | type) == "string") |
    select((.lastMergeSourceCommit.commitId // "") | test("^[a-fA-F0-9]{40}$")) |
    select((.lastMergeTargetCommit.commitId // "") | test("^[a-fA-F0-9]{40}$")) |
    {version:1, id:.pullRequestId, repo:.repository.id,
     source:.sourceRefName, target:.targetRefName,
     head:.lastMergeSourceCommit.commitId, base:.lastMergeTargetCommit.commitId,
     title, description:(.description // ""), draft:(.isDraft // false),
     autoCompleteSetBy, reviewers:([.reviewers[]? | {id,vote,isRequired}] | sort_by(.id)),
     policies:([$policies.value[]? | {id: .configuration.id,
       revision:.configuration.revision, status, configuration:.configuration}] | sort_by(.id))}
  ' <<< "$pr"
}

pr_policy_hold_matches() {
  local pr_id="$1" pr="$2" policies="$3" key file
  [ -n "${STATE_DIR:-}" ] || return 1
  [[ "$pr_id" =~ ^[0-9]+$ ]] || return 1
  file="$STATE_DIR/pr-${pr_id}.policy-hold.json"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  key=$(pr_policy_hold_key "$pr" "$policies") || return 1
  [ -n "$key" ] && [ "$(cat "$file" 2>/dev/null)" = "$key" ]
}

pr_policy_hold_record() {
  local pr_id="$1" pr="$2" policies="$3" key file tmp
  [ -n "${STATE_DIR:-}" ] || return 1
  [[ "$pr_id" =~ ^[0-9]+$ ]] || return 1
  key=$(pr_policy_hold_key "$pr" "$policies") || return 1
  [ -n "$key" ] || return 1
  file="$STATE_DIR/pr-${pr_id}.policy-hold.json"
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if ! printf '%s\n' "$key" > "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

pr_policy_hold_clear() {
  local pr_id="$1"
  [ -n "${STATE_DIR:-}" ] || return 0
  [[ "$pr_id" =~ ^[0-9]+$ ]] || return 1
  rm -f "$STATE_DIR/pr-${pr_id}.policy-hold.json"
}
