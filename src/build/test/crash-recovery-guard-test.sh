#!/usr/bin/env bash
# Mock overrides are called indirectly by sourced/extracted production code.
# shellcheck disable=SC1091,SC2016,SC2034,SC2329
set -euo pipefail
BOT="$(cd "$(dirname "$0")/../pr-bot" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
source "$BOT/pr_event_guard.sh"
# Extract only shipped definitions. Never source the daemon entrypoint.
sed -n '/^pr_recovery_request() {/,/^# Run crash recovery in background/p' "$BOT/start.sh" | sed '$d' > "$T/functions.sh"
source "$T/functions.sh"
REAL_GIT=$(command -v git)
git() { [ "$1" = check-ref-format ] && "$REAL_GIT" "$@"; }
curl() { echo 'Unexpected network' >&2; return 99; }
get_ado_auth_header_cached() { echo 'fixture'; }
ADO_ORG=example ADO_PROJECT=project ADO_REPO=repo
REPO=11111111-1111-1111-1111-111111111111
PROJECT=22222222-2222-2222-2222-222222222222
BASE_REPO=$(jq -cn --arg r "$REPO" --arg p "$PROJECT" '{id:$r,name:"repo",project:{id:$p,name:"project"}}')
BASE_PR=$(jq -cn --argjson repo "$BASE_REPO" '{pullRequestId:42,repository:$repo,title:"normal",description:"",sourceRefName:"refs/heads/feature",targetRefName:"refs/heads/main",lastMergeSourceCommit:{commitId:("a"*40)},status:"active"}')
BASE_RECORD=$(jq -cn --arg r "$REPO" '{version:2,org:"example",project:"project",pr:"42",repoId:$r,leaseThreadId:"5",leaseCommentId:"2",pid:123,host:"test",leaseStarted:100,leaseExpires:200,crashedAt:150,exitCode:"1",sourceRef:"refs/heads/feature",targetRef:"refs/heads/main",head:("a"*40)}')
BASE_THREADS='{"count":1,"value":[{"id":5,"comments":[{"id":1,"content":"<!-- pr-bot-status:PR-42 -->"},{"id":2,"content":"<!-- pr-bot-lease:{\"host\":\"test\",\"pid\":123,\"ts\":150,\"status\":\"failed\"} -->"}]}]}'
reset() {
  printf '%s' "$BASE_PR" > "$T/pr"
  printf '%s' "$BASE_REPO" > "$T/repo"
  printf '%s' "$BASE_RECORD" > "$T/pr-42.crashed"
  printf '%s' "$BASE_THREADS" > "$T/threads"
  : > "$T/calls"; : > "$T/posts"
  rm -f "$T/fail" "$T/change" "$T/bad-post" "$T/replace" "$T/change-threads"
}
edit() { jq "$2" "$T/$1" > "$T/edit"; mv "$T/edit" "$T/$1"; }
pr_recovery_request() {
  printf '%s %s\n' "${2:-GET}" "$1" >> "$T/calls"
  [ ! -f "$T/fail" ] || return 1
  if [ "${2:-GET}" = POST ]; then
    printf '%s' "$3" >> "$T/posts"
    [ ! -f "$T/replace" ] || printf 'replacement' > "$T/pr-42.crashed"
    [ ! -f "$T/bad-post" ] || { printf '{}'; return; }
    printf '%s' "$3" | jq '. + {id:3}'
  elif [[ "$1" == */threads?* ]]; then
    cat "$T/threads"
    if [ -f "$T/change-threads" ]; then edit threads "$(cat "$T/change-threads")"; fi
    if [ -f "$T/change" ]; then edit pr "$(cat "$T/change")"; fi
  elif [[ "$1" == */pullRequests/42?* ]]; then cat "$T/pr"
  elif [[ "$1" == */repositories/repo?* ]]; then cat "$T/repo"
  else echo 'Unexpected endpoint' >&2; return 99; fi
}
PASS=0 FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else echo "FAIL: $*"; FAIL=$((FAIL+1)); fi; }
blocked() { pr_recover_record "$T/pr-42.crashed" >/dev/null 2>&1 && return 1; [ -f "$T/pr-42.crashed" ] && [ ! -s "$T/posts" ]; }
reset; check pr_recover_record "$T/pr-42.crashed"; check test ! -f "$T/pr-42.crashed"; check test -s "$T/posts"
for expr in 'del(.version)' '.pr="../42"' '.repoId="33333333-3333-3333-3333-333333333333"' '.org="foreign"' '.project="foreign"' '.leaseThreadId="5/../6"' '.leaseExpires="oops"' '.host="`danger`"' '.head=("b"*40)' '.sourceRef="refs/heads/other"' '.targetRef="refs/heads/other"' '.pid=456' '.crashedAt=99'; do
 reset; edit pr-42.crashed "$expr"; check blocked
done
reset; printf 'garbage' >> "$T/pr-42.crashed"; check blocked
reset; printf '%s' "$BASE_RECORD" >> "$T/pr-42.crashed"; check blocked
for expr in '.title="[no-bot] stop"' '.description="[NO-BOT] stop"' '.sourceRefName="refs/heads/feature-wip"' '.status="completed"' '.repository.id="33333333-3333-3333-3333-333333333333"'; do
 reset; edit pr "$expr"; check blocked
done
reset; edit pr '.title="[no-auto] normal"'; check pr_recover_record "$T/pr-42.crashed"
reset; touch "$T/fail"; check blocked
for value in '{}' 'garbage' '{"count":1,"value":[]}' "$BASE_THREADS$BASE_THREADS"; do
 reset; printf '%s' "$value" > "$T/threads"; check blocked
done
for expr in '.value[0].id=6' '.value[0].comments[0].content="wrong"' '.value[0].comments[1].id=3' '.value[0].comments[1].content="pr-bot-lease: malformed"' '.value[0].comments[1].content="<!-- pr-bot-lease:{bad} -->"' '.value[0].comments[1].content="<!-- pr-bot-lease:{\"host\":\"test\",\"pid\":123,\"ts\":151,\"status\":\"failed\"} -->"'; do
 reset; edit threads "$expr"; check blocked
done

reset; edit threads '.value[0].comments[1].content="<!-- pr-bot-lease:{\"host\":\"test\",\"pid\":123,\"ts\":100,\"expires\":200} -->"'; check pr_recover_record "$T/pr-42.crashed"
reset; edit threads '.value[0].comments += [{id:3,content:"<!-- pr-bot-lease:{\"host\":\"other\",\"pid\":456,\"ts\":100,\"expires\":9999999999} -->"}]'; check blocked
for expr in '.title="[no-bot] stop"' '.sourceRefName="refs/heads/feature-wip"' '.lastMergeSourceCommit.commitId=("b"*40)'; do
 reset; printf '%s' "$expr" > "$T/change"; check blocked
done
reset; touch "$T/bad-post"; pr_recover_record "$T/pr-42.crashed" >/dev/null 2>&1 || true; check test -f "$T/pr-42.crashed"; check test -s "$T/posts"
# A later read of the matching notice confirms the uncertain first result.
content=$(jq -r '.content' "$T/posts")
jq --arg c "$content" '.value[0].comments += [{id:3,content:$c}]' "$T/threads" > "$T/edit"; mv "$T/edit" "$T/threads"
: > "$T/posts"; check pr_recover_record "$T/pr-42.crashed"; check test ! -s "$T/posts"; check test ! -f "$T/pr-42.crashed"
reset; touch "$T/replace"; pr_recover_record "$T/pr-42.crashed" >/dev/null 2>&1 || true; check test "$(cat "$T/pr-42.crashed")" = replacement
# Exact envelope parsing must not silently drop partially formatted leases.
for content in '<!-- pr-bot-lease:missing-json -->' '<!-- pr-bot-lease:{"host":"test"}' 'prefix <!-- pr-bot-lease:{} -->'; do
 reset
 jq --arg c "$content" '.value[0].comments += [{id:4,content:$c}]' "$T/threads" > "$T/edit"; mv "$T/edit" "$T/threads"
 check blocked
done
# The crashed process itself is not exempt from the active-lease check.
reset
edit pr-42.crashed '.leaseExpires=9999999999'
edit threads '.value[0].comments[1].content="<!-- pr-bot-lease:{\"host\":\"test\",\"pid\":123,\"ts\":100,\"expires\":9999999999} -->"'
check blocked
# A lease reused by another owner or marked done is stale, not ours to release.
 reset; edit threads '.value[0].comments[1].content="<!-- pr-bot-lease:{\"host\":\"test\",\"pid\":123,\"ts\":150,\"status\":\"done\"} -->"'; check blocked
reset; edit threads '.value[0].comments[1].content="<!-- pr-bot-lease:{\"host\":\"other\",\"pid\":456,\"ts\":150,\"status\":\"failed\"} -->"'; check blocked
# A new active lease arriving during setup is caught at the second threads read.
reset
printf '%s' '.value[0].comments += [{id:3,content:"<!-- pr-bot-lease:{\"host\":\"other\",\"pid\":456,\"ts\":100,\"expires\":9999999999} -->"}]' > "$T/change-threads"
check blocked
check test "$(grep -c '/threads?' "$T/calls")" = 2
check test "$(grep -cE '^(POST|PATCH|PUT|DELETE) ' "$T/calls" || true)" = 0
# Actual transport is extracted separately so failures cannot be masked by mocks.
sed -n '/^pr_recovery_request() {/,/^}/p' "$BOT/start.sh" > "$T/transport.sh"
(
 source "$T/transport.sh"
 # shellcheck disable=SC2329 # invoked by extracted transport
 curl() { printf '%s\n' "$*" > "$T/curl-args"; cat > "$T/curl-stdin"; return 22; }
 if pr_recovery_request 'https://example.invalid' POST '{}'; then exit 1; fi
 grep -q -- '-fsS --max-time 15' "$T/curl-args" || exit 1
 if grep -q fixture "$T/curl-args"; then exit 1; fi
 grep -qx 'Authorization: fixture' "$T/curl-stdin"
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
# Daemon pass exercises the portable lock and retains failed records. No network.
reset; touch "$T/fail"
STATE_DIR="$T"
recover_crashed_prs >/dev/null
check test -f "$T/pr-42.crashed"
check test ! -d "$T/.recover.lock"
check grep -q 'LEASE_STARTED=$now' "$BOT/pr_lease.sh"
check grep -q 'version:2,org:' "$BOT/pr_router.sh"
# Record refs are binding context, never optional sentinel values.
for expr in '.sourceRef=""' '.targetRef=""' '.sourceRef="refs/heads/"' '.targetRef="refs/heads/a..b"' '.sourceRef="refs/tags/release"' '.sourceRef="refs/heads/-option"' '.sourceRef="refs/heads/with space"'; do
 reset; edit pr-42.crashed "$expr"; check blocked; check test ! -s "$T/calls"
done
reset; edit pr-42.crashed '.sourceRef="" | .targetRef=""'
edit pr '.sourceRefName="refs/heads/new-source" | .targetRefName="refs/heads/production"'
check blocked; check test ! -s "$T/calls"
# Deterministic contention tests use the actual shared lock and pause only the
# local unlink/rename. No HTTP occurs while either state lock is held.
wait_signal() {
 local i
 for ((i=0;i<200;i++)); do [ ! -f "$1" ] || return 0; sleep 0.01; done
 return 1
}
# Force the portable branch using an isolated executable path without flock.
# Do not override the shell's command builtin (it changes errexit propagation).
mkdir "$T/portable-tools"
for tool in jq mktemp mkdir sleep mv rm cat rmdir; do
 ln -s "$(command -v "$tool")" "$T/portable-tools/$tool"
done
saved_path="$PATH"
export PATH="$T/portable-tools"
reset
new_record=$(printf '%s' "$BASE_RECORD" | jq '.crashedAt=151')
(
 rm() {
  if [ "${2:-}" = "$T/pr-42.crashed" ]; then
   : > "$T/unlink-entered"; wait_signal "$T/unlink-release" || return 1
  fi
  command rm "$@"
 }
 pr_crash_state_update "$T/pr-42.crashed" remove "$BASE_RECORD"
) & remover=$!
check wait_signal "$T/unlink-entered"
(
 mkdir() { if [ "$1" = "$T/pr-42.crashed.state.lock" ]; then : > "$T/publisher-contending"; fi; command mkdir "$@"; }
 pr_crash_state_publish "$T/pr-42.crashed" "$new_record"
) & publisher=$!
check wait_signal "$T/publisher-contending"
check test "$(cat "$T/pr-42.crashed")" = "$BASE_RECORD"
: > "$T/unlink-release"
check wait "$remover"; check wait "$publisher"
check test "$(cat "$T/pr-42.crashed")" = "$new_record"
# Reverse ordering: publisher owns the lock first, so stale removal must compare
# against the new atomically published record and leave it intact.
reset
(
 mv() {
  : > "$T/rename-entered"; wait_signal "$T/rename-release" || return 1
  command mv "$@"
 }
 pr_crash_state_publish "$T/pr-42.crashed" "$new_record"
) & publisher=$!
check wait_signal "$T/rename-entered"
check test "$(cat "$T/pr-42.crashed")" = "$BASE_RECORD"
(
 mkdir() { if [ "$1" = "$T/pr-42.crashed.state.lock" ]; then : > "$T/remover-contending"; fi; command mkdir "$@"; }
 pr_crash_state_update "$T/pr-42.crashed" remove "$BASE_RECORD"
) & remover=$!
check wait_signal "$T/remover-contending"
: > "$T/rename-release"
check wait "$publisher"
rc=0; wait "$remover" || rc=$?; check test "$rc" = 1
check test "$(cat "$T/pr-42.crashed")" = "$new_record"
# Unavailable portable lock retains a complete pending publication, not a partial
# live record. Skip sleeps in this deterministic lock-failure fixture.
reset
(
 mkdir() { return 1; }
 sleep() { :; }
 pr_crash_state_publish "$T/pr-42.crashed" "$new_record"
) >/dev/null 2>&1 && fail_pending=1 || fail_pending=0
check test "$fail_pending" = 0
check test "$(cat "$T/pr-42.crashed")" = "$BASE_RECORD"
pending_files=("$T"/pr-42.crashed.pending.*)
check test "${#pending_files[@]}" = 1
check test "$(cat "${pending_files[0]}")" = "$new_record"
export PATH="$saved_path"
# Both runtime entrypoints source this snapshotted module, and cleanup uses it.
check grep -q 'source "$RUNTIME_SCRIPT_DIR/pr_event_guard.sh"' "$BOT/start.sh"
check grep -q 'source "$SCRIPT_DIR/pr_event_guard.sh"' "$BOT/pr_router.sh"
check grep -q 'pr_crash_state_publish "$STATE_DIR/pr-${PR_ID}.crashed"' "$BOT/pr_router.sh"
printf 'Crash recovery guard: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
