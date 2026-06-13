#!/usr/bin/env bash
set -euo pipefail

# orphan-reaper-test.sh — Injectable unit test for the pr-bot orphan reaper's
# kill predicate (_select_orphan_candidates) WITHOUT needing a real cgroup.
#
# The reaper is parameterized on (root, procs_path), so we extract the real
# helper functions out of start.sh (testing the actual shipped code, not a copy)
# and run them against:
#   * a fabricated cgroup.procs file, and
#   * a real, controlled process topology we spawn here.
#
# Topology:
#   ROOT (bash) ── CHILD (sleep)        ← the daemon's "protected subtree"
#   ORPHAN (sleep)                      ← in-cgroup but OFF ROOT's tree → MUST be flagged
#   DENY (exe renamed git-gc)           ← off-tree but comm-denylisted   → MUST be spared
#   PID 1, ROOT itself                  ← never flagged (root / init)
#
# Asserts the predicate flags EXACTLY {ORPHAN}, and that the age gate filters it
# out when the age threshold is raised.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
START_SH="$(cd "$SCRIPT_DIR/../pr-bot" && pwd)/start.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$START_SH" ]; then
  echo "❌ Cannot find start.sh at $START_SH"
  exit 1
fi

# --- Extract the REAL predicate helpers from start.sh (counted-brace parser so
# nested col-0 '}' in case arms / heredocs / inner blocks don't truncate) ---
extract_fn() {
  awk -v fn="$1" '
    !found && $0 ~ "^"fn"\\(\\) \\{" { found=1; depth=0 }
    found {
      s=$0; depth += gsub(/{/,"{",s); s=$0; depth -= gsub(/}/,"}",s)
      print
      if (found && depth == 0) exit
    }
  ' "$START_SH"
}

for fn in get_pid_rss_mb _collect_subtree_pids get_cgroup_procs_for_pid _select_orphan_candidates _kill_subtree reap_orphaned_subprocesses; do
  body="$(extract_fn "$fn")"
  if [ -z "$body" ]; then
    echo "❌ Failed to extract function '$fn' from start.sh"
    exit 1
  fi
  eval "$body"
done

# Predicate config (mirror start.sh defaults; age 0 so our fresh procs aren't filtered)
ORPHAN_REAP_ENABLED=true
ORPHAN_REAP_AGE_SECS=0
ORPHAN_REAP_GRACE_SECS=1
ORPHAN_REAP_COMM_DENYLIST="git git-gc git-maintenance git-repack git-pack-objects fsmonitor--daemon git-credential gpg gpg-agent ssh ssh-agent"
REAP_LAST_COUNT=0

TMPDIR_TEST="$(mktemp -d)"
SPAWNED=()
cleanup() {
  local p
  for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

# --- Build the real process topology ---

# ROOT: a bash that backgrounds a CHILD sleep, records its PID, then waits.
"$(command -v bash)" -c 'sleep 600 & echo $! > "'"$TMPDIR_TEST"'/child.pid"; wait' &
ROOT=$!
SPAWNED+=("$ROOT")

# Wait for the child pid file (the CHILD must be in ROOT's subtree).
CHILD=""
for _ in $(seq 1 50); do
  if [ -s "$TMPDIR_TEST/child.pid" ]; then
    CHILD="$(cat "$TMPDIR_TEST/child.pid" 2>/dev/null | tr -d ' ')"
    [[ "$CHILD" =~ ^[0-9]+$ ]] && break
  fi
  sleep 0.1
done
if [[ "$CHILD" =~ ^[0-9]+$ ]]; then
  SPAWNED+=("$CHILD")
else
  echo "❌ Setup failed: could not capture CHILD pid under ROOT"
  exit 1
fi

# ORPHAN: a sleep that is a sibling of ROOT (a child of THIS shell), i.e. NOT in
# subtree(ROOT) — the leaked-off-tree case the reaper must catch.
sleep 600 &
ORPHAN=$!
SPAWNED+=("$ORPHAN")

# DENY: an executable whose comm is denylisted (git-gc), also off ROOT's tree.
cp "$(command -v sleep)" "$TMPDIR_TEST/git-gc"
"$TMPDIR_TEST/git-gc" 600 &
DENY=$!
SPAWNED+=("$DENY")

# Give procs a moment to materialize in /proc and the process table.
sleep 0.3

# --- Fabricated cgroup.procs: everything "in the cgroup" ---
PROCS_FILE="$TMPDIR_TEST/cgroup.procs"
printf '%s\n' "$ROOT" "$CHILD" "$ORPHAN" "$DENY" "1" > "$PROCS_FILE"

echo "🧪 Orphan reaper predicate test"
echo "   ROOT=$ROOT CHILD=$CHILD ORPHAN=$ORPHAN DENY(git-gc)=$DENY"
echo ""

# --- Run the predicate (read-only; no kills) ---
OUT="$(_select_orphan_candidates "$ROOT" "$PROCS_FILE" || true)"
FLAGGED_PIDS="$(echo "$OUT" | awk 'NF{print $1}' | sort -n | tr '\n' ' ' | sed 's/ *$//')"

in_flagged() { echo " $FLAGGED_PIDS " | grep -q " $1 "; }

# Assertion 1: ORPHAN is flagged
if in_flagged "$ORPHAN"; then
  pass "ORPHAN ($ORPHAN) flagged as off-tree leak"
else
  fail "ORPHAN ($ORPHAN) NOT flagged — got: [$FLAGGED_PIDS]"
fi

# Assertion 2: CHILD (in ROOT subtree) is spared
if in_flagged "$CHILD"; then
  fail "CHILD ($CHILD) wrongly flagged — it is in ROOT's protected subtree"
else
  pass "CHILD ($CHILD) spared (in ROOT subtree)"
fi

# Assertion 3: ROOT itself is spared
if in_flagged "$ROOT"; then
  fail "ROOT ($ROOT) wrongly flagged — must never reap the root"
else
  pass "ROOT ($ROOT) spared (== root)"
fi

# Assertion 4: DENY (comm=git-gc) is spared by the denylist
if in_flagged "$DENY"; then
  fail "DENY ($DENY, comm=git-gc) wrongly flagged — denylist failed"
else
  pass "DENY ($DENY, comm=git-gc) spared (comm denylist)"
fi

# Assertion 5: PID 1 is spared
if in_flagged "1"; then
  fail "PID 1 wrongly flagged — must never reap init"
else
  pass "PID 1 spared (init)"
fi

# Assertion 6: EXACTLY the orphan is flagged (nothing else slipped through)
if [ "$FLAGGED_PIDS" = "$ORPHAN" ]; then
  pass "Flagged set is EXACTLY {ORPHAN}"
else
  fail "Flagged set is [$FLAGGED_PIDS], expected exactly [$ORPHAN]"
fi

# Assertion 7: age gate — raise the threshold so even the orphan is filtered out
OLD_AGE="$ORPHAN_REAP_AGE_SECS"
ORPHAN_REAP_AGE_SECS=999999
OUT_AGED="$(_select_orphan_candidates "$ROOT" "$PROCS_FILE" || true)"
ORPHAN_REAP_AGE_SECS="$OLD_AGE"
if [ -z "$(echo "$OUT_AGED" | awk 'NF{print}')" ]; then
  pass "Age gate (≥999999s) filters out the fresh orphan"
else
  fail "Age gate failed — still flagged: [$(echo "$OUT_AGED" | awk 'NF{print $1}' | tr '\n' ' ')]"
fi

# Assertion 8: empty/unreadable procs path → no-op (no crash, no output)
OUT_EMPTY="$(_select_orphan_candidates "$ROOT" "$TMPDIR_TEST/does-not-exist" || true)"
if [ -z "$OUT_EMPTY" ]; then
  pass "Missing cgroup.procs path → no-op (no candidates)"
else
  fail "Missing procs path produced output: [$OUT_EMPTY]"
fi

# --- End-to-end kill path: reap_orphaned_subprocesses (injected procs_path) ---
# Exercises the FULL shipped function (TERM/KILL via _kill_subtree) against the
# real topology, proving it kills ONLY the orphan and spares ROOT/CHILD/DENY.
echo ""
echo "🧪 Reaper kill path (reap_orphaned_subprocesses)"
reap_orphaned_subprocesses "$ROOT" 0 "$PROCS_FILE" >/dev/null 2>&1 || true
# Grace for TERM→KILL to land.
sleep "$((ORPHAN_REAP_GRACE_SECS + 1))"

# Assertion 9: REAP_LAST_COUNT reports exactly 1
if [ "${REAP_LAST_COUNT:-0}" -eq 1 ]; then
  pass "REAP_LAST_COUNT == 1 (exactly one subtree reaped)"
else
  fail "REAP_LAST_COUNT == ${REAP_LAST_COUNT:-0}, expected 1"
fi

# Assertion 10: ORPHAN is actually dead
if kill -0 "$ORPHAN" 2>/dev/null; then
  fail "ORPHAN ($ORPHAN) still alive after reap"
else
  pass "ORPHAN ($ORPHAN) terminated by reaper"
fi

# Assertion 11: ROOT + CHILD (protected subtree) untouched
if kill -0 "$ROOT" 2>/dev/null && kill -0 "$CHILD" 2>/dev/null; then
  pass "ROOT ($ROOT) + CHILD ($CHILD) untouched (protected subtree)"
else
  fail "ROOT/CHILD wrongly killed — protected subtree breached"
fi

# Assertion 12: DENY (git-gc) untouched by the kill path
if kill -0 "$DENY" 2>/dev/null; then
  pass "DENY ($DENY, comm=git-gc) untouched (denylist held through kill path)"
else
  fail "DENY ($DENY) wrongly killed — denylist failed in kill path"
fi

# Assertion 13: ORPHAN_REAP_ENABLED=false short-circuits (no kills, count 0)
sleep 600 &
ORPHAN2=$!
SPAWNED+=("$ORPHAN2")
printf '%s\n' "$ROOT" "$CHILD" "$DENY" "$ORPHAN2" "1" > "$PROCS_FILE"
sleep 0.2
OLD_EN="$ORPHAN_REAP_ENABLED"
ORPHAN_REAP_ENABLED=false
reap_orphaned_subprocesses "$ROOT" 0 "$PROCS_FILE" >/dev/null 2>&1 || true
ORPHAN_REAP_ENABLED="$OLD_EN"
if kill -0 "$ORPHAN2" 2>/dev/null && [ "${REAP_LAST_COUNT:-0}" -eq 0 ]; then
  pass "ORPHAN_REAP_ENABLED=false short-circuits (no kill, count 0)"
else
  fail "Disabled reaper still acted (ORPHAN2 alive=$(kill -0 "$ORPHAN2" 2>/dev/null && echo yes || echo no), count=${REAP_LAST_COUNT:-0})"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
