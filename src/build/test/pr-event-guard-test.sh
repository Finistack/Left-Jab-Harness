#!/usr/bin/env bash
# Fixture globals are consumed by sourced/extracted functions; jq programs are literal.
# shellcheck disable=SC2034,SC2016,SC1091
set -euo pipefail
# Offline only: exercise shipped guard/policy/lease functions and router slices.
# No daemon/router entrypoint, model, credentials, remote git or real HTTP is run.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOT="$(cd "$SCRIPT_DIR/../pr-bot" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
expect_rc() {
  local want="$1" label="$2" got=0
  shift 2
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (rc=$got, want=$want)"; fi
}
log() { :; }
debug() { :; }
# A tripwire for accidental direct networking or model invocation in extracted code.
curl() { echo 'Unexpected curl' >&2; return 99; }
claude() { echo 'Unexpected model' >&2; return 99; }
REAL_GIT=$(command -v git)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REPO=11111111-1111-1111-1111-111111111111
PROJECT=22222222-2222-2222-2222-222222222222
FOREIGN=33333333-3333-3333-3333-333333333333
ADO_ORG=example-org ADO_PROJECT=example-project ADO_REPO=example-repo
ORIGIN="https://dev.azure.com/example-org/example-project/_git/example-repo"
LOCAL_HEAD="$HEAD_A"
git() {
  if [ "${1:-}" = check-ref-format ]; then "$REAL_GIT" "$@"; return; fi
  case "$*" in
    *'remote get-url --all origin') printf '%s\n' "$ORIGIN" ;;
    *'remote get-url --push --all origin') printf '%s\n' "${PUSH_ORIGINS-$ORIGIN}" ;;
    *'rev-parse HEAD') printf '%s\n' "$LOCAL_HEAD" ;;
    *) echo "Unexpected git: $*" >&2; return 99 ;;
  esac
}
# shellcheck source=../pr-bot/pr_event_guard.sh
source "$BOT/pr_event_guard.sh"
# shellcheck source=../pr-bot/pr_policies.sh
source "$BOT/pr_policies.sh"
BASE_REPO=$(jq -cn --arg id "$REPO" --arg project "$PROJECT" --arg remote "$ORIGIN" \
  '{id:$id,name:"example-repo",project:{id:$project,name:"example-project"},remoteUrl:$remote,sshUrl:"git@ssh.dev.azure.com:v3/example-org/example-project/example-repo"}')
BASE_PR=$(jq -cn --argjson repo "$BASE_REPO" --arg head "$HEAD_A" \
  '{pullRequestId:42,repository:$repo,title:"A normal PR",description:"",sourceRefName:"refs/heads/feature",targetRefName:"refs/heads/main",lastMergeSourceCommit:{commitId:$head},status:"active"}')
BASE_EVENT=$(jq -cn --argjson pr "$BASE_PR" \
  '{notificationId:"event-1",eventType:"ms.vss-code.git-pullrequest-comment-event",resource:{pullRequest:$pr,comment:{content:"review"}}}')
reset_fixture() {
  printf '%s' "$BASE_REPO" > "$TEST_DIR/repo.json"
  printf '%s' "$BASE_PR" > "$TEST_DIR/pr.json"
  printf '{"value":[]}' > "$TEST_DIR/threads.json"
  : > "$TEST_DIR/calls"
  rm -f "$TEST_DIR/fail-read" "$TEST_DIR/after-vote" "$TEST_DIR/after-classify"
  PR_GUARD_SOURCE_REF="" PR_GUARD_TARGET_REF=""
  PR_GUARD_POLICY_HEAD="" PR_GUARD_RISK_LEVEL=unknown PR_GUARD_RELEASING_LEASE=0
  LEASE_THREAD_ID="" LEASE_COMMENT_ID=""
  ADO_REPO=example-repo ADO_PROJECT=example-project
  ORIGIN="https://dev.azure.com/example-org/example-project/_git/example-repo"
  unset PUSH_ORIGINS
  RISK=low
}
edit_pr() {
  jq "$@" "$TEST_DIR/pr.json" > "$TEST_DIR/next.json"
  mv "$TEST_DIR/next.json" "$TEST_DIR/pr.json"
}
ado_api_request() {
  local url="$1" method="${2:-GET}"
  printf '%s %s\n' "$method" "$url" >> "$TEST_DIR/calls"
  if [ "$method" != GET ]; then
    if [[ "$url" == */reviewers/* ]] && [ -f "$TEST_DIR/after-vote" ]; then
      cp "$TEST_DIR/after-vote" "$TEST_DIR/pr.json"
    fi
    printf '{}'
    return 0
  fi
  case "$url" in
    */pullRequests/42\?api-version=7.1)
      [ ! -f "$TEST_DIR/fail-read" ] || return 1
      cat "$TEST_DIR/pr.json" ;;
    */threads\?api-version=7.1) cat "$TEST_DIR/threads.json" ;;
    */repositories/*\?api-version=7.1) cat "$TEST_DIR/repo.json" ;;
    */_apis/connectionData) printf '{"authenticatedUser":{"id":"bot-id"}}' ;;
    */policy/evaluations\?*) printf '{"value":[]}' ;;
    *) echo "Unexpected API: $url" >&2; return 99 ;;
  esac
}
ado_api_call() { pr_guard_api_call "$@"; }
classify_pr_risk() {
  [ ! -f "$TEST_DIR/after-classify" ] || cp "$TEST_DIR/after-classify" "$TEST_DIR/pr.json"
  printf '{"risk":"%s","reasoning":"offline fixture"}' "$RISK"
}
no_writes() { ! grep -qE '^(POST|PATCH|PUT|DELETE) ' "$TEST_DIR/calls"; }
no_vote() { ! grep -q 'PUT .*reviewers/' "$TEST_DIR/calls"; }
no_complete() { ! grep -q 'PATCH .*pullRequests/42?' "$TEST_DIR/calls"; }
init() { pr_guard_init "$BASE_EVENT"; }

# jq -e must not accept a bad first document because a valid last one passes.
for first in '{"resource":{"pullRequest":{"pullRequestId":"../../not-an-id"}}}' '{}' '[]' 'null' "$BASE_EVENT"; do
  multi=$(printf '%s\n%s' "$first" "$BASE_EVENT")
  expect_rc 1 'concatenated roots rejected even with valid final event' pr_event_valid "$multi"
done
expect_rc 1 'empty JSON stream rejected' pr_event_valid ''
expect_rc 1 'whitespace-only JSON stream rejected' pr_event_valid '   '
expect_rc 1 'valid-first malformed-last JSON rejected' pr_event_valid "${BASE_EVENT}{"
# Exercise the actual queue filename constructor: rejected content never reaches
# its event-ID extraction or filesystem write. No daemon entrypoint is run.
DEFER_FUNCTION=$(sed -n '/^defer_message() {/,/^}/p' "$BOT/start.sh")
eval "$DEFER_FUNCTION"
DEFER_QUEUE_DIR="$TEST_DIR/deferred"
mkdir -p "$DEFER_QUEUE_DIR"
malformed_first=$(printf '%s\n%s' '{"resource":{"pullRequest":{"pullRequestId":"../../not-an-id"}}}' "$BASE_EVENT")
expect_rc 0 'malformed-first replay is dropped before queue filename construction' defer_message "$malformed_first"
expect_rc 0 'rejected JSON stream creates no queue file' test -z "$(find "$DEFER_QUEUE_DIR" -type f -print)"
reset_fixture
printf '{}\n%s' "$BASE_REPO" > "$TEST_DIR/repo.json"
expect_rc 1 'repository response must also have a single root' init
reset_fixture
printf '{}\n%s' "$BASE_PR" > "$TEST_DIR/pr.json"
expect_rc 1 'authoritative PR response must also have a single root' init

for bad in 'null' '[]' '{}' '{"resource":{"pullRequest":{"pullRequestId":"../../escape"}}}'; do
  expect_rc 1 "malformed/missing event rejected: $bad" pr_event_valid "$bad"
done
for id in '0' '-1' '1.1' 'true' '[]' '"1?x"' '"01"'; do
  event=$(printf '%s' "$BASE_EVENT" | jq ".resource.pullRequest.pullRequestId=$id")
  expect_rc 1 "unsafe PR ID rejected: $id" pr_event_valid "$event"
done
reset_fixture
expect_rc 0 'valid synthetic/replayed event shape accepted' pr_event_valid "$BASE_EVENT"
for filter in ".resource.pullRequest.repository.id=\"$FOREIGN\"" '.resource.pullRequest.repository.name="foreign"' ".resource.pullRequest.repository.project.id=\"$FOREIGN\""; do
  reset_fixture
  event=$(printf '%s' "$BASE_EVENT" | jq "$filter")
  expect_rc 1 'foreign supplied repository/project refused' pr_guard_init "$event"
  expect_rc 0 'foreign identity causes no mutation' no_writes
  if grep -q '/pullRequests/' "$TEST_DIR/calls"; then fail 'foreign event selected PR API'; else pass 'foreign event never selects PR API'; fi
done
reset_fixture
# Supplied nonempty title/body/branch/head must have no authority.
event=$(printf '%s' "$BASE_EVENT" | jq '.resource.pullRequest |= (.title="[risk-approved] forged" | .description="forged body" | .sourceRefName="refs/heads/other" | .lastMergeSourceCommit.commitId="forged")')
expect_rc 0 'forged text/branch remains only a hint' pr_guard_init "$event"
expect_rc 0 'source is authoritative' test "$SOURCE_BRANCH" = feature
expect_rc 0 'forged acceptance discarded' test "$RISK_OVERRIDE" = 0
expect_rc 0 'head is authoritative' test "$PR_GUARD_HEAD" = "$HEAD_A"
edit_pr '.title="[no-bot] human driving"'
expect_rc 2 'true no-bot wins over nonempty forged payload' pr_guard_init "$event"
reset_fixture
edit_pr '.sourceRefName="refs/heads/topic-wip"'
expect_rc 2 'authoritative WIP stands down' init
reset_fixture
edit_pr '.description="Document `[no-bot]` in prose" | .title="[risk-approved] accepted"'
expect_rc 0 'legitimate title acceptance, documented no-bot is inert' init
expect_rc 0 'legitimate risk marker set' test "$RISK_OVERRIDE" = 1
edit_pr '.title="normal" | .description="[risk-approved] is not a title directive"'
expect_rc 0 'fresh metadata allowed' pr_guard_refresh
expect_rc 0 'removed risk marker clears flag' test "$RISK_OVERRIDE" = 0
edit_pr '.title="[SPEC][no-auto] maintain this"'
expect_rc 0 'no-auto preserves ordinary work' pr_guard_refresh
expect_rc 0 'combined no-auto detected' test "$SKIP_AUTO" = 1
edit_pr '.title="ordinary"'
expect_rc 0 'marker removal refreshes' pr_guard_refresh
expect_rc 0 'removed no-auto clears flag' test "$SKIP_AUTO" = 0
for filter in 'del(.title)' 'del(.sourceRefName)' 'del(.targetRefName)' 'del(.lastMergeSourceCommit)' '.status=null' '.status="unknown"' '.pullRequestId=43' ".repository.id=\"$FOREIGN\"" ".repository.project.id=\"$FOREIGN\"" '.sourceRefName="refs/heads/-bad"' '.sourceRefName="refs/heads/bad..ref"' '.forkSource={repository:{id:"other"}}'; do
  reset_fixture
  edit_pr "$filter"
  expect_rc 1 "invalid authoritative context refused: $filter" init
done
reset_fixture
printf '{}' > "$TEST_DIR/repo.json"
expect_rc 1 'malformed repository lookup refused' init
reset_fixture
ADO_REPO="$REPO" ADO_PROJECT="$PROJECT"
expect_rc 0 'configured repository/project GUIDs supported' init
reset_fixture
init
expect_rc 0 'matching HTTPS origin allowed' pr_guard_origin_matches /mock
ORIGIN="https://user@dev.azure.com/example-org/example-project/_git/example-repo"
expect_rc 0 'same HTTPS origin with username allowed' pr_guard_origin_matches /mock
ORIGIN="git@ssh.dev.azure.com:v3/example-org/example-project/example-repo"
expect_rc 0 'matching SSH origin allowed' pr_guard_origin_matches /mock
ORIGIN="https://dev.azure.com/example-org/example-project/_git/foreign"
expect_rc 1 'different local origin refused' pr_guard_origin_matches /mock
reset_fixture
init
PUSH_ORIGINS="https://dev.azure.com/example-org/example-project/_git/foreign"
expect_rc 1 'matching fetch origin cannot hide a foreign effective pushurl' pr_guard_origin_matches /mock
PUSH_ORIGINS=$(printf '%s\n%s' "$ORIGIN" 'git@ssh.dev.azure.com:v3/example-org/example-project/example-repo')
expect_rc 0 'multiple effective push URLs for the same repository allowed' pr_guard_origin_matches /mock
PUSH_ORIGINS=$(printf '%s\n%s' "$ORIGIN" 'https://other.example/foreign')
expect_rc 1 'every effective push URL must match, not only the first' pr_guard_origin_matches /mock
PUSH_ORIGINS=""
expect_rc 1 'missing effective push destination fails closed' pr_guard_origin_matches /mock
ORIGIN=$(printf '%s\n%s' 'https://dev.azure.com/example-org/example-project/_git/example-repo' 'https://other.example/foreign')
unset PUSH_ORIGINS
expect_rc 1 'additional foreign fetch URL fails closed' pr_guard_origin_matches /mock
reset_fixture
init
edit_pr '.title="[risk-approved] accepted"'
pr_guard_refresh
: > "$TEST_DIR/fail-read"
expect_rc 1 'authoritative read failure fails closed' pr_guard_refresh
expect_rc 0 'read failure clears risk acceptance' test "$RISK_OVERRIDE" = 0
expect_rc 0 'read failure disables auto actions' test "$SKIP_AUTO" = 1
reset_fixture
init
edit_pr '.sourceRefName="refs/heads/renamed"'
expect_rc 75 'changed source ref yields, never retargets run' pr_guard_refresh
reset_fixture
init
edit_pr '.targetRefName="refs/heads/release"'
expect_rc 75 'changed target ref invalidates run' pr_guard_refresh
reset_fixture
init
edit_pr --arg head "$HEAD_B" '.lastMergeSourceCommit.commitId=$head'
expect_rc 75 'stale expected source head yields' pr_guard_refresh "$HEAD_A"

# Every router-issued mutation uses the same fail-closed boundary wrapper.
for target in 'git/repositories/REPO/pullRequests/42/threads' 'wit/workitems/$Task' 'policy/evaluations/evaluation' 'git/repositories/REPO/pullRequests/42/threads/9'; do
  reset_fixture
  init
  target=${target/REPO/$REPO}
  edit_pr '.title="[no-bot] stop"'
  expect_rc 1 "new no-bot blocks mutation at $target" ado_api_call "$ADO_BASE/$target?api-version=7.1" POST '{}'
  expect_rc 0 'no forbidden write reached transport' no_writes
done
reset_fixture
init
LEASE_THREAD_ID=9 LEASE_COMMENT_ID=8 PR_GUARD_RELEASING_LEASE=1
edit_pr '.title="[no-bot] stop"'
expect_rc 0 'owned lease release remains possible on standdown' ado_api_call "$ADO_BASE/git/repositories/$REPO/pullRequests/42/threads/9/comments/8?api-version=7.1" PATCH '{}'
expect_rc 1 'cleanup exception cannot write another comment' ado_api_call "$ADO_BASE/git/repositories/$REPO/pullRequests/42/threads/9/comments/7?api-version=7.1" PATCH '{}'

# no-auto blocks only auto actions, while ordinary authorized maintenance remains.
reset_fixture
init
edit_pr '.title="[no-auto] maintain only"'
expect_rc 0 'no-auto still permits ordinary work-item writes' ado_api_call "$ADO_BASE/wit/workitems/9?api-version=7.1" PATCH '{}'
reset_fixture
init
: > "$TEST_DIR/fail-read"
expect_rc 1 'failed authoritative read blocks work-item write' ado_api_call "$ADO_BASE/wit/workitems/9?api-version=7.1" PATCH '{}'
expect_rc 0 'failed read has no mutation side effect' no_writes
for status in '"completed"' '"abandoned"' 2 3; do
  reset_fixture
  edit_pr ".status=$status"
  expect_rc 2 "non-active authoritative status stands down: $status" init
done
reset_fixture
event=$(printf '%s' "$BASE_EVENT" | jq '.notificationId="event\\npoison"')
expect_rc 1 'notification IDs cannot inject dedupe lines' pr_event_valid "$event"

# Verify Git itself expands pushInsteadOf independently of the fetch URL.
# This uses only a disposable local repository and synthetic URLs, with system
# and user config disabled. No network, credentials, fetch or push is used.
check_push_rewrite() {
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git() { "$REAL_GIT" "$@"; }
    git init -q "$TEST_DIR/url-config" || return 1
    git -C "$TEST_DIR/url-config" config remote.origin.url 'fixture:example-repo'
    git -C "$TEST_DIR/url-config" config 'url.https://dev.azure.com/example-org/example-project/_git/.insteadOf' 'fixture:'
    pr_guard_origin_matches "$TEST_DIR/url-config" || return 1
    git -C "$TEST_DIR/url-config" config 'url.https://other.example/.pushInsteadOf' 'fixture:'
    if pr_guard_origin_matches "$TEST_DIR/url-config"; then return 1; fi
  )
}
reset_fixture
init
expect_rc 0 'effective pushInsteadOf redirection is rejected despite valid fetch URL' check_push_rewrite

# Exercise the real policy gate with a mocked classifier and transport.
reset_fixture
init
RISK=high
edit_pr '.title="[risk-approved] accepted"'
expect_rc 0 'legitimate HIGH acceptance preserves full policy gate' run_policy_gate 42 "$REPO" "$PROJECT" /mock 0 1
if grep -q 'PUT .*reviewers/' "$TEST_DIR/calls" && grep -q 'PATCH .*pullRequests/42?' "$TEST_DIR/calls"; then pass 'legitimate vote and auto-complete emitted'; else fail 'legitimate policy writes missing'; fi
reset_fixture
init
edit_pr '.title="[no-auto] human merges"'
expect_rc 0 'no-auto policy gate can still report risk' run_policy_gate 42 "$REPO" "$PROJECT" /mock 0 1
expect_rc 0 'authoritative no-auto blocks stale-argument vote' no_vote
expect_rc 0 'authoritative no-auto blocks stale-argument completion' no_complete
reset_fixture
init
jq --arg head "$HEAD_B" '.lastMergeSourceCommit.commitId=$head' "$TEST_DIR/pr.json" > "$TEST_DIR/after-classify"
expect_rc 1 'source advances during classification: gate refuses stale risk' run_policy_gate 42 "$REPO" "$PROJECT" /mock 0 1
expect_rc 0 'no stale risk writes' no_writes
for changed in '.title="[no-auto] stop merging"' '.title="[no-bot] stop all"' '.title="risk approval removed"'; do
  reset_fixture
  init
  RISK=high
  edit_pr '.title="[risk-approved] accepted"'
  jq "$changed" "$TEST_DIR/pr.json" > "$TEST_DIR/after-vote"
  expected=0
  [[ "$changed" != *no-bot* ]] || expected=1
  expect_rc "$expected" 'policy respects changed markers after vote' run_policy_gate 42 "$REPO" "$PROJECT" /mock 0 1
  expect_rc 0 "fresh marker blocks completion: $changed" no_complete
done

# Extract and exercise shipped router intake; never execute the bot entrypoint.
INTAKE=$(sed -n '/^# Notification replay suppression/,/^# --- Per-PR execution lock/{ /^# --- Per-PR execution lock/!p; }' "$BOT/pr_router.sh")
run_intake() { ( PAYLOAD="$1"; eval "$INTAKE"; : > "$TEST_DIR/accepted" ); }
reset_fixture
STATE_DIR="$TEST_DIR/state"
mkdir -p "$STATE_DIR"
expect_rc 0 'first notification admitted' run_intake "$BASE_EVENT"
expect_rc 0 'first notification reached trusted continuation' test -f "$TEST_DIR/accepted"
rm -f "$TEST_DIR/accepted"
: > "$TEST_DIR/calls"
expect_rc 0 'duplicate/replayed notification skips cleanly' run_intake "$BASE_EVENT"
expect_rc 0 'duplicate did not continue' test ! -f "$TEST_DIR/accepted"
expect_rc 0 'duplicate requires no new API call' test ! -s "$TEST_DIR/calls"
event=$(printf '%s' "$BASE_EVENT" | jq --arg foreign "$FOREIGN" '.notificationId="event-2" | .resource.pullRequest.repository.id=$foreign')
expect_rc 1 'foreign queued event refused by common intake' run_intake "$event"
if grep -qx 'event-2' "$STATE_DIR/seen-notifications.log"; then fail 'foreign event poisoned dedupe'; else pass 'foreign event cannot consume legitimate notification ID'; fi

# Active distributed lease behavior is unchanged and uses only the bound repo.
# shellcheck source=../pr-bot/pr_lease.sh
source "$BOT/pr_lease.sh"
reset_fixture
init
jq -cn --argjson expires "$(($(date +%s) + 600))" '{value:[{id:9,comments:[{content:"<!-- pr-bot-status:PR-42 -->"},{content:("<!-- pr-bot-lease:"+({host:"other-host",pid:1,ts:1,expires:$expires,status:"active"}|tojson)+" -->")}]}]}' > "$TEST_DIR/threads.json"
expect_rc 0 'active foreign lease still prevents acquisition' check_pr_lease 42 "$REPO"
expect_rc 0 'lease check never writes' no_writes

# Extract real cleanup and lock acquisition, using temporary local state only.
CLEANUP=$(sed -n '/^cleanup() {/,/^}/p' "$BOT/pr_router.sh")
LOCK=$(sed -n '/^if ! mkdir "$PR_LOCK_DIR"/,/^# State management/{ /^# State management/!p; }' "$BOT/pr_router.sh")
eval "$CLEANUP"
PR_ID=42
PR_LOCK_DIR="$STATE_DIR/pr-42.lock"
mkdir -p "$PR_LOCK_DIR"
printf '%s\n%s\n' "$(date +%s)" "$$" > "$PR_LOCK_DIR/pid"
printf 'winner' > "$STATE_DIR/pr-42.inflight"
PR_LOCK_OWNED=false LOCK_ACQUIRE_WINDOW_SECS=10
( trap cleanup EXIT; eval "$LOCK"; : > "$TEST_DIR/incorrectly-acquired" )
expect_rc 0 'live owner lock remains intact' test -f "$PR_LOCK_DIR/pid"
expect_rc 0 'live owner breadcrumb remains intact' test "$(cat "$STATE_DIR/pr-42.inflight")" = winner
expect_rc 0 'losing router never entered work' test ! -f "$TEST_DIR/incorrectly-acquired"
# Ensure normal owned cleanup still removes its own lock and captures true rc=75.
( PR_LOCK_OWNED=true; LEASE_THREAD_ID="" LEASE_COMMENT_ID=""; trap cleanup EXIT; exit 75 ) || rc=$?
expect_rc 0 'owned cleanup removes own lock' test ! -d "$PR_LOCK_DIR"
expect_rc 0 'yield code retained' test "$(cat "$STATE_DIR/pr-42.lastexit")" = 75
expect_rc 0 'yield does not make crash marker' test ! -f "$STATE_DIR/pr-42.crashed"

# Main-shell checkpoints preserve clean standdown, failure, and yield exit codes.
run_checkpoint() { ( pr_guard_require "${1:-}"; : > "$TEST_DIR/checkpoint-action" ); }
reset_fixture
init
edit_pr '.title="[no-bot] stop"'
expect_rc 0 'checkpoint standdown is a clean exit' run_checkpoint
expect_rc 0 'standdown never reaches worktree/model/push action' test ! -f "$TEST_DIR/checkpoint-action"
reset_fixture
init
: > "$TEST_DIR/fail-read"
expect_rc 1 'checkpoint read failure aborts' run_checkpoint
expect_rc 0 'failed read never reaches action' test ! -f "$TEST_DIR/checkpoint-action"
reset_fixture
init
edit_pr '.sourceRefName="refs/heads/other"'
expect_rc 75 'checkpoint changed branch yields' run_checkpoint
expect_rc 0 'changed branch never reaches action' test ! -f "$TEST_DIR/checkpoint-action"

# Exercise the shipped recovery retry loop with a function-only git mock. No git
# push process is ever launched; the mock verifies the expected lease argument.
RECOVERY=$(sed -n '/^      PR_BOT_PUSH_RETRIES=/,/^      if \[ "$_push_ok"/{ /^      if \[ "$_push_ok"/!p; }' "$BOT/pr_router.sh")
ORIGINAL_GIT=$(declare -f git)
run_recovery() {
  (
    PUSH_LEASE_HEAD="$HEAD_A" WORK_DIR=/mock PR_BOT_PUSH_RETRIES=2
    mock_pushes=0 _push_ok=false _push_is_concurrency=false
    # shellcheck disable=SC2329 # called by the extracted recovery loop
    git() {
      case "$*" in
        *' push '* )
          mock_pushes=$((mock_pushes + 1))
          printf '%s\n' "$*" >> "$TEST_DIR/pushes"
          if [ "$mock_pushes" = 1 ]; then
            [[ "$*" == *"--force-with-lease=refs/heads/feature:$HEAD_A"* ]] || return 90
          else
            [[ "$*" == *"--force-with-lease=refs/heads/feature:$HEAD_B"* ]] || return 91
          fi
          case "$MOCK_PUSH" in
            retry|ref-race) [ "$mock_pushes" -gt 1 ] && return 0 ;;
            auth) echo 'authentication failed' >&2; return 1 ;;
          esac
          echo 'stale info' >&2; return 1 ;;
        *' fetch '* )
          edit_pr --arg head "$HEAD_B" '.lastMergeSourceCommit.commitId=$head'
          printf '%s' "$HEAD_B" > "$TEST_DIR/shared-ref"
          [ "$MOCK_PUSH" != optout ] || edit_pr '.title="[no-bot] stop"'
          return 0 ;;
        *'rev-parse origin/feature')
          cat "$TEST_DIR/shared-ref"
          # A different worktree fetch changes the shared ref after capture.
          [ "$MOCK_PUSH" != ref-race ] || printf '%s' "$HEAD_A" > "$TEST_DIR/shared-ref"
          return 0 ;;
        *' rebase '* )
          local rebase_target="${!#}"
          printf '%s\n' "$rebase_target" >> "$TEST_DIR/rebases"
          [ "$rebase_target" = "$HEAD_B" ] || return 92
          return 0 ;;
        *'remote get-url --all origin') printf '%s\n' "$ORIGIN" ;;
        *'remote get-url --push --all origin')
          if [ "$MOCK_PUSH" = push-redirect ] && [ -f "$TEST_DIR/shared-ref" ]; then
            printf 'https://other.example/foreign\n'
          else
            printf '%s\n' "$ORIGIN"
          fi ;;
        check-ref-format*) "$REAL_GIT" "$@" ;;
        *) return 99 ;;
      esac
    }
    eval "$RECOVERY"
    printf '%s %s %s\n' "$_push_ok" "$_push_is_concurrency" "$mock_pushes" > "$TEST_DIR/push-result"
  )
}
for mode in retry always auth optout ref-race push-redirect; do
  reset_fixture
  init
  rm -f "$TEST_DIR/pushes" "$TEST_DIR/rebases" "$TEST_DIR/push-result" "$TEST_DIR/shared-ref"
  MOCK_PUSH="$mode"
  expected=0
  [ "$mode" != push-redirect ] || expected=1
  expect_rc "$expected" "recovery loop mock runs: $mode" run_recovery
  case "$mode" in
    retry) expect_rc 0 'stale lease rebases then retries with pinned new tip' test "$(cat "$TEST_DIR/push-result")" = 'true true 2' ;;
    push-redirect)
      expect_rc 0 'pushurl changed after fetch blocks the retry' test "$(wc -l < "$TEST_DIR/pushes" | tr -d ' ')" = 1
      expect_rc 0 'push destination failure never reaches success' test ! -f "$TEST_DIR/push-result" ;;
    ref-race)
      expect_rc 0 'shared-ref change still rebases the exact captured SHA' test "$(cat "$TEST_DIR/rebases")" = "$HEAD_B"
      expect_rc 0 'race fixture moved shared ref away from captured SHA' test "$(cat "$TEST_DIR/shared-ref")" = "$HEAD_A"
      expect_rc 0 'retry succeeds only with exact rebase/lease SHA binding' test "$(cat "$TEST_DIR/push-result")" = 'true true 2' ;;
    always) expect_rc 0 'contention retries remain bounded for yield' test "$(cat "$TEST_DIR/push-result")" = 'false true 3' ;;
    auth) expect_rc 0 'non-transient push failure does not masquerade as contention' test "$(cat "$TEST_DIR/push-result")" = 'false false 1' ;;
    optout)
      expect_rc 0 'opt-out during recovery prevents rebase and retry' test ! -f "$TEST_DIR/rebases"
      expect_rc 0 'opt-out terminates remaining recovery actions' test ! -f "$TEST_DIR/push-result" ;;
  esac
done
eval "$ORIGINAL_GIT"

# Exercise the real retrying transport with a shell-function curl fixture. A
# marker arriving during backoff must prevent a second mutation request.
TRANSPORT=$(sed -n '/^ado_api_request() {/,/^}/p' "$BOT/pr_router.sh")
reset_fixture
init
run_retry_transport() {
  (
    eval "$TRANSPORT"
    # shellcheck disable=SC2329 # called by the extracted transport
    _ado_auth() { printf 'mock-auth'; }
    # shellcheck disable=SC2329 # called by the extracted transport
    sleep() { :; }
    # shellcheck disable=SC2329 # called by the extracted transport
    curl() {
      local output="" headers="" method=GET url=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) output="$2"; shift 2 ;;
          -D) headers="$2"; shift 2 ;;
          -X) method="$2"; shift 2 ;;
          -H|-w|-d|--max-time) shift 2 ;;
          -s) shift ;;
          *) url="$1"; shift ;;
        esac
      done
      : > "$headers"
      if [ "$method" = GET ]; then
        [[ "$url" == */pullRequests/42\?api-version=7.1 ]] || return 99
        cat "$TEST_DIR/pr.json" > "$output"
        printf 200
      else
        printf '%s\n' "$method" >> "$TEST_DIR/http-mutations"
        edit_pr '.title="[no-bot] stop during backoff"'
        printf '{}' > "$output"
        printf 429
      fi
    }
    ado_api_call "$ADO_BASE/wit/workitems/9?api-version=7.1" PATCH '{}'
  )
}
expect_rc 1 'delayed write retry rechecks authoritative opt-out' run_retry_transport
expect_rc 0 'no second mutation after changed marker' test "$(wc -l < "$TEST_DIR/http-mutations" | tr -d ' ')" = 1

# Wiring checks ensure every ingress validates before using event-derived paths,
# and the boundary hook cannot disappear while helper-level tests keep passing.
python3 - "$BOT" <<'PY'
from pathlib import Path
import sys
bot=Path(sys.argv[1]); r=(bot/'pr_router.sh').read_text(); s=(bot/'start.sh').read_text()
assert r.index('pr_guard_init "$PAYLOAD"') < r.index('git -C "$REPO_ROOT" ls-remote') < r.index('acquire_pr_lease "$PR_ID"')
assert r.index('acquire_pr_lease "$PR_ID"') < r.index('# --- Branch resolution:')
assert 'ado_api_call() { pr_guard_api_call "$@"; }' in r
assert 'pr_guard_require\nensure_pr_work_item' in r
assert 'pr_guard_require\n    WORK_DIR=' in r
assert 'pr_guard_require\n\n# Use git worktree' in r
assert 'pr_guard_require\n  run_claude_session' in r
assert 'while :; do\n        pr_guard_require' in r
assert 'push "--force-with-lease=refs/heads/${SOURCE_BRANCH}:${PUSH_LEASE_HEAD}"' in r
assert 'rebase "$_retry_head"' in r
assert 'pr_guard_origin_matches "$WORK_DIR"' in r
assert 'pr_guard_require\n    ado_api_call' in r
assert '"$SCRIPT_DIR/ado_resolve.sh"' not in r
for payload in ('"$MSG_BODY"','"$deferred_body"','"$replay_body"','"$msg_body"'):
    assert 'pr_event_valid '+payload in s
assert s.index('pr_event_valid "$MSG_BODY"') < s.index('_FL_PR_ID=$(echo "$MSG_BODY"')
print('  PASS: intake, replay and consequential boundary wiring')
PY
PASS=$((PASS + 1))
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
