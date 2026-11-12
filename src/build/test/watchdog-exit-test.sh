#!/usr/bin/env bash
# Fixture globals are consumed by the eval-loaded production functions.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
START="$SCRIPT_DIR/../pr-bot/start.sh"
STATE_DIR=$(mktemp -d);trap 'rm -rf "$STATE_DIR"' EXIT
# Exercise actual watchdog and reaper with deterministic process stubs.
eval "$(sed -n '/^kill_oversized_claudes() {/,/^}/p' "$START")"
eval "$(sed -n '/^reap_jobs() {/,/^}/p' "$START")"
declare -A PR_BUDGET PR_QUEUE_FILE PR_DISPATCH_ID
ACTIVE_PIDS=(123456);PR_BUDGET[123456]=100;PR_QUEUE_FILE[123456]="$STATE_DIR/queue";PR_DISPATCH_ID[123456]=123
MIN_SESSION_KILL_MB=200;MEMORY_BUDGET_MB=1000
printf 'payload\n' > "$STATE_DIR/queue"
ALIVE=1
kill() { [ "$ALIVE" -eq 1 ]; }
wait() { return 0; }
_subtree_rss_mb() { echo 300; }
get_cgroup_unreclaimable_mb() { echo 0; }
_kill_subtree() {
  # The persisted forced marker must exist BEFORE signals are sent.
  [ "$(cat "$STATE_DIR/pr-123.watchdog-$1.lastexit")" = 137 ]
  printf '0\n' > "$STATE_DIR/pr-123.lastexit"
  ALIVE=0
}
kill_oversized_claudes >/dev/null
reap_jobs > "$STATE_DIR/output"
grep -q 'exited with code 137' "$STATE_DIR/output"
if grep -q 'completed successfully' "$STATE_DIR/output"; then exit 1; fi
[ -f "$STATE_DIR/queue" ]
[ ! -f "$STATE_DIR/pr-123.watchdog-123456.lastexit" ]
# An ordinary zero exit is still successful and clears its queue.
ACTIVE_PIDS=(234567);PR_DISPATCH_ID[234567]=234;PR_QUEUE_FILE[234567]="$STATE_DIR/normal-queue"
printf 'payload\n' > "$STATE_DIR/normal-queue"; printf '0\n' > "$STATE_DIR/pr-234.lastexit"
reap_jobs > "$STATE_DIR/output"
grep -q 'completed successfully' "$STATE_DIR/output"
[ ! -f "$STATE_DIR/normal-queue" ]
echo 'PASS: watchdog marker precedes kill, overrides cleanup zero, preserves queue; normal success unchanged'
