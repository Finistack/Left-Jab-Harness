#!/usr/bin/env bash
set -euo pipefail

# heartbeat-resilience-test.sh — Unit tests for the heartbeat's two resilience
# mechanisms, both added after the 2026-09-29 incident: a transient ENOSPC at
# the deferred-queue write killed pr_heartbeat.sh, and orphan-PR recovery stayed
# dead for 8h while the systemd unit still reported `active` (WatchdogSec covers
# the main process, which kept pinging; nothing supervises the heartbeat child).
#
#   1. pr_heartbeat.sh — the deferred-queue write guard. A failed write must skip
#      ONE PR, not exit the `while true` recovery loop.
#   2. start.sh — ensure_heartbeat_alive. A dead heartbeat must be respawned from
#      the 60s maintenance tick; a live one must be left strictly alone.
#
# Both are extracted from the SHIPPED scripts (not copied), so these tests fail
# if either guard is removed or reworded.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PR_BOT_DIR="$(cd "$SCRIPT_DIR/../pr-bot" && pwd)"
START_SH="$PR_BOT_DIR/start.sh"
HEARTBEAT_SH="$PR_BOT_DIR/pr_heartbeat.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

for f in "$START_SH" "$HEARTBEAT_SH"; do
  if [ ! -f "$f" ]; then
    echo "❌ Cannot find $f"
    exit 1
  fi
done

TMPDIR_TEST="$(mktemp -d)"
# Fake heartbeats are long sleeps. If this script exits while one is still alive
# it inherits our stdout pipe and holds it open, hanging anything downstream
# (e.g. `./test.sh | tail`) long after the run finished. Track and reap them.
SPAWNED=()
cleanup() {
  local p
  for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

# Counted-brace parser so nested col-0 '}' in case arms / heredocs don't truncate
# (mirrors orphan-reaper-test.sh).
extract_fn() {
  awk -v fn="$1" '
    !found && $0 ~ "^"fn"\\(\\) \\{" { found=1; depth=0 }
    found {
      s=$0; depth += gsub(/{/,"{",s); s=$0; depth -= gsub(/}/,"}",s)
      print
      if (found && depth == 0) exit
    }
  ' "$2"
}

# ---------------------------------------------------------------------------
# 1. start.sh::ensure_heartbeat_alive
# ---------------------------------------------------------------------------
echo "🧪 ensure_heartbeat_alive (start.sh)"
BODY="$(extract_fn ensure_heartbeat_alive "$START_SH")"
if [ -z "$BODY" ]; then
  fail "Failed to extract ensure_heartbeat_alive from start.sh"
else
  # A stand-in heartbeat: a long sleep we can kill on demand. It MUST be named
  # pr_heartbeat.sh — ensure_heartbeat_alive respawns that exact path under
  # $RUNTIME_SCRIPT_DIR, so the name is part of the contract under test.
  cat > "$TMPDIR_TEST/pr_heartbeat.sh" <<'EOF'
#!/usr/bin/env bash
# Detach from the caller's stdout/stderr so a surviving child can never hold the
# test runner's pipe open (which would hang `test.sh | tail`).
exec >/dev/null 2>&1
sleep 600
EOF
  chmod +x "$TMPDIR_TEST/pr_heartbeat.sh"

  RUNTIME_SCRIPT_DIR="$TMPDIR_TEST"
  HEARTBEAT_INTERVAL_SECS=300
  eval "$BODY"

  # Start one exactly as start.sh does.
  "$RUNTIME_SCRIPT_DIR/pr_heartbeat.sh" &
  HEARTBEAT_PID=$!
  HB1="$HEARTBEAT_PID"
  SPAWNED+=("$HB1")
  sleep 0.3

  # Assertion 1: a LIVE heartbeat is left strictly alone (same PID, still alive).
  ensure_heartbeat_alive >/dev/null 2>&1 || true
  if [ "$HEARTBEAT_PID" = "$HB1" ] && kill -0 "$HB1" 2>/dev/null; then
    pass "Live heartbeat left alone (PID $HB1 unchanged)"
  else
    fail "Live heartbeat disturbed (was $HB1, now $HEARTBEAT_PID)"
  fi

  # Assertion 2: a DEAD heartbeat is respawned, and the new PID is live.
  kill -KILL "$HB1" 2>/dev/null || true
  wait "$HB1" 2>/dev/null || true
  sleep 0.2
  ensure_heartbeat_alive >/dev/null 2>&1 || true
  SPAWNED+=("$HEARTBEAT_PID")
  if [ "$HEARTBEAT_PID" != "$HB1" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    pass "Dead heartbeat respawned (new PID $HEARTBEAT_PID)"
  else
    fail "Dead heartbeat NOT respawned (PID still $HEARTBEAT_PID)"
  fi

  # Assertion 3: respawn is idempotent — a second call must not spawn again.
  HB2="$HEARTBEAT_PID"
  ensure_heartbeat_alive >/dev/null 2>&1 || true
  if [ "$HEARTBEAT_PID" = "$HB2" ]; then
    pass "Respawn idempotent (PID $HB2 unchanged on repeat call)"
  else
    fail "Respawn spawned again (was $HB2, now $HEARTBEAT_PID)"
  fi

  kill -KILL "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 2. pr_heartbeat.sh — deferred-queue write guard
# ---------------------------------------------------------------------------
echo ""
echo "🧪 pr_heartbeat.sh deferred-queue write guard"

# Extract the SHIPPED block verbatim: from the payload build through the
# recovered counter. A reworded or unguarded write fails this test.
GUARD="$(awk '
  /local_payload=\$\(build_synthetic_payload/ { found=1 }
  found { print }
  found && /recovered=\$\(\(recovered \+ 1\)\)/ { exit }
' "$HEARTBEAT_SH")"

if [ -z "$GUARD" ]; then
  fail "Failed to extract the deferred-queue write block from pr_heartbeat.sh"
else
  # Run the shipped block as a REAL subprocess with `set -euo pipefail`, exactly
  # as pr_heartbeat.sh runs it. An in-process subshell is NOT faithful: bash
  # suppresses `set -e` inside a subshell that is itself an `if` condition, so
  # the unguarded version would appear to "survive" and the regression would slip
  # through (verified — that is how this test was first written). A separate
  # `bash` process has unambiguous `set -e` semantics, and reaching the sentinel
  # line at the end is the assertion.
  #
  # The block reads its inputs from the enclosing loop, so the probe reproduces
  # them; `continue` requires a real enclosing loop.
  #
  # A write failure is forced WITHOUT a full disk by pointing the target at a
  # path that is a DIRECTORY, so the redirect fails with EISDIR.
  probe() {
    # $1 = directory the block writes into. Prints REACHED_END iff the loop lived.
    local dir="$1"
    cat > "$TMPDIR_TEST/probe.sh" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
log() { echo "     [log] \$*"; }
build_synthetic_payload() { echo '{"eventType":"heartbeat-recovery"}'; }
pr_json='{"pullRequestId":4242}'
local_pr_id=4242
recovered=0
local_defer_dir="$dir"
local_defer_file="\$local_defer_dir/pr-4242.json"
for _ in 1; do
$GUARD
done
echo "REACHED_END"
PROBE
    chmod +x "$TMPDIR_TEST/probe.sh"
    timeout 30 "$TMPDIR_TEST/probe.sh" 2>&1 || true
  }

  # Assertion 4: a FAILED write must not exit the loop.
  mkdir -p "$TMPDIR_TEST/fail/deferred/pr-4242.json"   # a DIRECTORY → write fails
  OUT_FAIL="$(probe "$TMPDIR_TEST/fail/deferred")"
  if printf '%s' "$OUT_FAIL" | grep -q 'REACHED_END'; then
    pass "Failed write did NOT exit the loop (guard held under set -e)"
  else
    fail "Failed write exited the loop — the heartbeat would die (the 2026-09-29 bug)"
  fi

  # Assertion 5: the happy path still queues normally (guard isn't over-eager).
  mkdir -p "$TMPDIR_TEST/ok/deferred"
  OUT_OK="$(probe "$TMPDIR_TEST/ok/deferred")"
  if printf '%s' "$OUT_OK" | grep -q 'REACHED_END' \
     && [ -s "$TMPDIR_TEST/ok/deferred/pr-4242.json" ]; then
    pass "Successful write still queues the PR (payload present)"
  else
    fail "Successful write broken — PR was not queued"
  fi

  # Assertion 6: the queued payload is the real synthetic payload, not a stub.
  if jq -e '.eventType == "heartbeat-recovery"' \
       "$TMPDIR_TEST/ok/deferred/pr-4242.json" >/dev/null 2>&1; then
    pass "Queued payload is the synthetic heartbeat event (valid JSON)"
  else
    fail "Queued payload malformed: [$(head -c 120 "$TMPDIR_TEST/ok/deferred/pr-4242.json" 2>/dev/null)]"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Wiring — the supervisor must actually be CALLED, not merely defined.
# ---------------------------------------------------------------------------
# A defined-but-uncalled ensure_heartbeat_alive reproduces the original failure
# exactly: the heartbeat dies and nothing notices. This is a source-level check
# because the call site is inside the daemon's ntfy read loop, which cannot be
# exercised without a live stream. The definition (`ensure_heartbeat_alive() {`)
# sits at column 0; only a real call is indented.
echo ""
echo "🧪 supervisor wiring (start.sh)"
if grep -qE '^[[:space:]]+ensure_heartbeat_alive[[:space:]]' "$START_SH"; then
  pass "ensure_heartbeat_alive is called in start.sh (wired into the maintenance tick)"
else
  fail "ensure_heartbeat_alive is defined but never called — the heartbeat would still die silently"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
