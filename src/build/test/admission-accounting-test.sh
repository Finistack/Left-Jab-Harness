#!/usr/bin/env bash
set -euo pipefail

# admission-accounting-test.sh — Unit test for the pr-bot admission memory
# accounting (get_cgroup_unreclaimable_mb) WITHOUT needing a real cgroup.
#
# THE BUG UNDER TEST (issue #8): the admission controller trusted cgroup v2
# memory.current, which includes reclaimable page cache + slab. Under
# MemoryHigh=max that cache accretes above the budget and is never reclaimed, so
# check_resource_budget deferred EVERY dispatch on memory the OOM killer would
# free for free — a silent multi-day wedge with ~7 MB of actual process RSS.
#
# We extract the REAL shipped helper from start.sh (not a copy), feed it
# synthetic memory.current / memory.stat fixtures, and assert it reports the
# UNRECLAIMABLE figure (memory.current − inactive_file − slab_reclaimable).

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

# --- Extract the REAL helper from start.sh (counted-brace parser, matching the
# orphan-reaper-test extractor so nested col-0 '}' don't truncate) ---
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

body="$(extract_fn get_cgroup_unreclaimable_mb)"
if [ -z "$body" ]; then
  echo "❌ Failed to extract function 'get_cgroup_unreclaimable_mb' from start.sh"
  exit 1
fi
eval "$body"

TMPDIR_TEST="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_TEST" 2>/dev/null || true; }
trap cleanup EXIT

CUR="$TMPDIR_TEST/memory.current"
STAT="$TMPDIR_TEST/memory.stat"

MB=$((1024 * 1024))

echo "🧪 Admission accounting: get_cgroup_unreclaimable_mb"

# --- Fixture 1: the live wedge shape — 1024 MB inactive_file + 436 MB
# slab_reclaimable + ~7 MB anon. memory.current ≈ 1467 MB but unreclaimable ≈ 7 MB. ---
echo $(( 1467 * MB )) > "$CUR"
cat > "$STAT" <<EOF
anon $(( 7 * MB ))
file $(( 1030 * MB ))
kernel_stack $(( 1 * MB ))
pagetables 524288
inactive_anon 4648960
active_anon 2514944
inactive_file $(( 1024 * MB ))
active_file $(( 6 * MB ))
unevictable 0
slab_reclaimable $(( 436 * MB ))
slab_unreclaimable $(( 2 * MB ))
EOF

got=$(get_cgroup_unreclaimable_mb "$CUR" "$STAT")
# 1467 − 1024 − 436 = 7
if [ "$got" -ge 5 ] && [ "$got" -le 9 ]; then
  pass "Wedge fixture → ~7 MB unreclaimable (got ${got} MB), not ~1467 MB raw"
else
  fail "Wedge fixture → expected ~7 MB, got ${got} MB"
fi

# --- Fixture 2: two live sessions, no cache — unreclaimable ≈ memory.current. ---
echo $(( 2200 * MB )) > "$CUR"
cat > "$STAT" <<EOF
anon $(( 2100 * MB ))
inactive_file $(( 50 * MB ))
slab_reclaimable $(( 20 * MB ))
slab_unreclaimable $(( 10 * MB ))
EOF
got=$(get_cgroup_unreclaimable_mb "$CUR" "$STAT")
# 2200 − 50 − 20 = 2130
if [ "$got" -ge 2125 ] && [ "$got" -le 2135 ]; then
  pass "Real-load fixture → ~2130 MB unreclaimable (got ${got} MB) — guard still trips on genuine pressure"
else
  fail "Real-load fixture → expected ~2130 MB, got ${got} MB"
fi

# --- Fixture 3: reclaimable pools absent from memory.stat → treated as 0
# (unreclaimable == memory.current), so a minimal-stat kernel never under-counts. ---
echo $(( 500 * MB )) > "$CUR"
cat > "$STAT" <<EOF
anon $(( 500 * MB ))
EOF
got=$(get_cgroup_unreclaimable_mb "$CUR" "$STAT")
if [ "$got" -ge 498 ] && [ "$got" -le 502 ]; then
  pass "Missing reclaimable fields → treated as 0 (got ${got} MB ≈ 500)"
else
  fail "Missing reclaimable fields → expected ~500 MB, got ${got} MB"
fi

# --- Fixture 4: reclaimable exceeds current (racey read) → clamps to 0, never negative. ---
echo $(( 100 * MB )) > "$CUR"
cat > "$STAT" <<EOF
inactive_file $(( 200 * MB ))
slab_reclaimable $(( 50 * MB ))
EOF
got=$(get_cgroup_unreclaimable_mb "$CUR" "$STAT")
if [ "$got" -eq 0 ]; then
  pass "Reclaimable > current → clamps to 0 (got ${got} MB, never negative)"
else
  fail "Reclaimable > current → expected 0, got ${got} MB"
fi

# --- Fixture 5: unreadable paths → non-zero return (callers fall back to subtree sum). ---
if get_cgroup_unreclaimable_mb "$TMPDIR_TEST/nope.current" "$TMPDIR_TEST/nope.stat" >/dev/null 2>&1; then
  fail "Unreadable paths → expected failure (return 1) for caller fallback"
else
  pass "Unreadable paths → returns non-zero (callers fall back)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
