#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2016
set -euo pipefail
BOT="$(cd "$(dirname "$0")/../pr-bot" && pwd)"
source "$BOT/pr_policy_hold.sh"
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
pr='{"pullRequestId":42,"repository":{"id":"repo"},"sourceRefName":"refs/heads/fix","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"lastMergeTargetCommit":{"commitId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"title":"fix","reviewers":[]}'
policies='{"value":[{"status":"approved","configuration":{"id":1,"revision":2,"type":{"id":"build"},"isBlocking":true,"isEnabled":true}}]}'
expect_miss() { if pr_policy_hold_matches 42 "$1" "$2"; then echo 'Unexpected hold match' >&2; exit 1; fi; }
expect_miss "$pr" "$policies"
pr_policy_hold_record 42 "$pr" "$policies"
pr_policy_hold_matches 42 "$pr" "$policies"
for change in '.title="[risk-approved] fix"' '.description="new intent"' '.lastMergeSourceCommit.commitId="cccccccccccccccccccccccccccccccccccccccc"' '.lastMergeTargetCommit.commitId="dddddddddddddddddddddddddddddddddddddddd"' '.targetRefName="refs/heads/release"' '.reviewers=[{"id":"human","vote":10}]' '.isDraft=true'; do
  expect_miss "$(jq "$change" <<< "$pr")" "$policies"
done
expect_miss "$pr" "$(jq '.value[0].configuration.revision=3' <<< "$policies")"
expect_miss "$pr" "$(jq '.value[0].status="rejected"' <<< "$policies")"
expect_miss '{}' "$policies"
expect_miss "$(jq 'del(.lastMergeTargetCommit)' <<< "$pr")" "$policies"
expect_miss "$pr" 'bad-json'
printf 'partial' > "$STATE_DIR/pr-42.policy-hold.json"
expect_miss "$pr" "$policies"
pr_policy_hold_record 42 "$pr" "$policies"
# Extract and exercise the real heartbeat readiness function (no loop/HTTP).
eval "$(sed -n '/^pr_is_ready_but_unmerged() {/,/^}/p' "$BOT/pr_heartbeat.sh")"
ADO_PROJECT=project ADO_BASE=https://example.invalid BUILD_POLICY_TYPE_ID=build REPO_ID=repo
detail=$(jq '.reviewers=[{id:"human",vote:10,isRequired:true}]' <<< "$pr")
list_pr=$(jq 'del(.reviewers) | .lastMergeSourceCommit.commitId |= ascii_upcase' <<< "$detail")
detail_response="$detail" detail_failure=0
lookups="$STATE_DIR/detail-lookups"
ado_api_call() {
  case "$1" in
    "$ADO_BASE/git/repositories/repo/pullRequests/42?api-version=7.1")
      printf '%s\n' "$1" >> "$lookups"
      [ "$detail_failure" = 0 ] || return 1
      printf '%s\n' "$detail_response"
      ;;
    "$ADO_BASE/policy/evaluations?"*) printf '%s\n' "$policies" ;;
    *) return 1 ;;
  esac
}
log() { :; }
pr_policy_hold_record 42 "$detail" "$policies"
expect_miss "$list_pr" "$policies"
if pr_is_ready_but_unmerged 42 "$list_pr"; then echo 'Heartbeat repeated a held PR' >&2; exit 1; fi
[ -s "$lookups" ]
detail_response=$(jq '.title="[risk-approved] fix"' <<< "$detail")
pr_is_ready_but_unmerged 42 "$list_pr"
detail_response='not-json'
pr_is_ready_but_unmerged 42 "$list_pr"
detail_response="$detail" detail_failure=1
pr_is_ready_but_unmerged 42 "$list_pr"
rm "$STATE_DIR/pr-42.policy-hold.json" "$lookups"
pr_is_ready_but_unmerged 42 "$list_pr"
[ ! -e "$lookups" ]
# Test actual gate with only external operations stubbed.
source "$BOT/pr_policies.sh"
RISK=high RISK_OVERRIDE=0 SKIP_AUTO=0
PR_DETAILS="$pr"
git() { echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
pr_guard_refresh() { :; }
classify_pr_risk() { printf '{"risk":"%s"}\n' "$RISK"; }
get_policy_evaluations() { echo "$policies"; }
detect_policy_issues() { echo '[]'; }
requeue_expired_policies() { :; }
auto_approve_pr() { return 1; }
auto_complete_pr() { return 1; }
post_risk_assessment() { :; }
run_policy_gate 42 repo project /fake
pr_policy_hold_matches 42 "$pr" "$policies"
RISK=unknown
run_policy_gate 42 repo project /fake
expect_miss "$pr" "$policies"
pr_policy_hold_record 42 "$pr" "$policies"
RISK=low
run_policy_gate 42 repo project /fake
expect_miss "$pr" "$policies"
RISK=high RISK_OVERRIDE=1
run_policy_gate 42 repo project /fake
expect_miss "$pr" "$policies"
# An unwritable local hint must not prevent the authoritative checks.
(
  pr_policy_hold_clear() { return 1; }
  post_risk_assessment() { printf 'reached\n' > "$STATE_DIR/assessment"; }
  RISK=low RISK_OVERRIDE=0
  run_policy_gate 42 repo project /fake
  [ -f "$STATE_DIR/assessment" ]
)
# A concurrent metadata change must not bind old classification to either intent.
RISK_OVERRIDE=0
classify_pr_risk() { echo '{"risk":"high"}'; }
post_risk_assessment() { PR_DETAILS=$(jq '.title="new intent"' <<< "$pr"); }
run_policy_gate 42 repo project /fake
expect_miss "$PR_DETAILS" "$policies"
expect_miss "$pr" "$policies"
[ ! -e "$STATE_DIR/pr-42.policy-hold.json" ]
echo 'Policy hold tests passed'

# Exercise the shipped dispatch decision: actionable work bypasses the hold.
pr_policy_hold_record 42 "$detail" "$policies"
detail_response="$detail" detail_failure=0
local_pr_id=42 REPO_ID=repo pr_json="$list_pr"
block=$(sed -n '/^    if ! pr_has_actionable_work/,/^    # Circuit breaker:/p' "$BOT/pr_heartbeat.sh" | sed '$d')
for actionable in comment build; do
  pr_has_actionable_work() { return 0; }
  dispatched=false
  for once in 1; do
    eval "$block"
    dispatched=true
  done
  [ "$dispatched" = true ] || exit 1
done
pr_has_actionable_work() { return 1; }
dispatched=false
for once in 1; do
  eval "$block"
  dispatched=true
done
[ "$dispatched" = false ] || exit 1
echo 'Heartbeat actionable bypass passed'
