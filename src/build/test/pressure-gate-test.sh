#!/usr/bin/env bash
set -euo pipefail

# pressure-gate-test.sh — Injectable unit test for the pr-bot macOS memory-pressure
# gate (system_memory_pressured) WITHOUT depending on the host's real memory state.
#
# Like orphan-reaper-test.sh, we extract the REAL function out of start.sh (so we
# exercise the shipped code, not a copy) and drive it with a mocked `sysctl` that
# returns scripted values for the two keys the gate reads:
#   * kern.memorystatus_vm_pressure_level   (1=normal, 2=warn, 4=critical)
#   * vm.swapusage                          ("... free = N.NNM ...")
#
# The regression this pins: a shared dev Mac sits at level 2 (warn) as its STEADY
# state and runs on dynamically-grown swap (~1.5 GB free is normal). The old gate
# (level > 1 OR free_swap < 2048) therefore deferred dispatch ~80x/hour while the
# kernel was never going to jetsam-kill anything, throttling the bot to 1-at-a-time.
# The fixed gate fires only at CRITICAL (>= SYSTEM_PRESSURE_LEVEL_THRESHOLD, default
# 4) or true swap exhaustion (< MIN_FREE_SWAP_MB, default 512).

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

# --- Extract the REAL function from start.sh (counted-brace parser so nested col-0
# '}' in case arms / inner blocks don't truncate) ---
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

body="$(extract_fn system_memory_pressured)"
if [ -z "$body" ]; then
  echo "❌ Failed to extract function 'system_memory_pressured' from start.sh"
  exit 1
fi
eval "$body"

# --- Mock sysctl: a function on the call path that returns scripted values.
# system_memory_pressured calls `command -v sysctl` then `sysctl -n <key>`, so we
# shadow BOTH: a `sysctl` function and a `command` wrapper that reports it exists.
MOCK_LEVEL=""
MOCK_SWAP_FREE_M=""   # e.g. "794.06" → free = 794.06M
sysctl() {
  # Emulate `sysctl -n <key>`
  local key="${3:-${2:-}}"
  case "$key" in
    kern.memorystatus_vm_pressure_level) [ -n "$MOCK_LEVEL" ] && printf '%s\n' "$MOCK_LEVEL"; return 0 ;;
    vm.swapusage) printf 'total = 24576.00M  used = 100.00M  free = %sM  (encrypted)\n' "${MOCK_SWAP_FREE_M:-8192.00}"; return 0 ;;
    *) return 1 ;;
  esac
}
command() {
  # Make `command -v sysctl` succeed (so the gate proceeds) but defer everything
  # else to the real builtin.
  if [ "${1:-}" = "-v" ] && [ "${2:-}" = "sysctl" ]; then echo "sysctl"; return 0; fi
  builtin command "$@"
}
export -f sysctl command 2>/dev/null || true

# Force the macOS branch regardless of the host the test runs on (CI is Linux). The
# function early-returns on non-Darwin, so we stub `uname` too.
uname() { if [ "${1:-}" = "-s" ]; then echo "Darwin"; else builtin uname "$@"; fi; }

# Gate config defaults (mirror start.sh)
SYSTEM_PRESSURE_GATE_ENABLED=true
SYSTEM_PRESSURE_LEVEL_THRESHOLD=4
MIN_FREE_SWAP_MB=512
SYSTEM_PRESSURE_REASON=""

# Helper: run the gate, echo "DEFER" (rc 0 = pressured) or "OK" (rc 1 = dispatch).
run_gate() {
  if system_memory_pressured; then echo "DEFER"; else echo "OK"; fi
}

echo "🧪 macOS memory-pressure gate test (system_memory_pressured)"
echo "   threshold=$SYSTEM_PRESSURE_LEVEL_THRESHOLD  min_free_swap=${MIN_FREE_SWAP_MB}MB"
echo ""

# 1. Normal (level 1), ample swap → OK to dispatch
MOCK_LEVEL=1; MOCK_SWAP_FREE_M="8192.00"
[ "$(run_gate)" = "OK" ] && pass "level=1 (normal), 8GB free → dispatch" \
                          || fail "level=1 should NOT defer (got DEFER, reason='$SYSTEM_PRESSURE_REASON')"

# 2. THE REGRESSION: warn (level 2) with ample swap → must NOT defer
MOCK_LEVEL=2; MOCK_SWAP_FREE_M="8192.00"
[ "$(run_gate)" = "OK" ] && pass "level=2 (warn) → dispatch (regression: old gate wrongly deferred)" \
                          || fail "level=2 (warn) must NOT defer — this is the throttling bug (reason='$SYSTEM_PRESSURE_REASON')"

# 3. Critical (level 4) → defer
MOCK_LEVEL=4; MOCK_SWAP_FREE_M="8192.00"
[ "$(run_gate)" = "DEFER" ] && pass "level=4 (critical) → defer (real jetsam risk)" \
                            || fail "level=4 (critical) MUST defer"

# 4. Swap exhaustion below floor (level normal) → defer
MOCK_LEVEL=1; MOCK_SWAP_FREE_M="300.00"
[ "$(run_gate)" = "DEFER" ] && pass "free_swap=300MB < 512MB floor → defer" \
                            || fail "swap below floor MUST defer (reason='$SYSTEM_PRESSURE_REASON')"

# 5. Typical dev-Mac swap (~1.6 GB free) is ABOVE the new 512 floor → OK
#    (the old 2048 floor wrongly deferred here)
MOCK_LEVEL=1; MOCK_SWAP_FREE_M="1606.00"
[ "$(run_gate)" = "OK" ] && pass "free_swap=1606MB (typical) → dispatch (old 2048 floor wrongly deferred)" \
                          || fail "1606MB free should NOT defer under the 512 floor (reason='$SYSTEM_PRESSURE_REASON')"

# 6. Env override: a constrained box can still gate at WARN by lowering the threshold
MOCK_LEVEL=2; MOCK_SWAP_FREE_M="8192.00"
OLD_T="$SYSTEM_PRESSURE_LEVEL_THRESHOLD"; SYSTEM_PRESSURE_LEVEL_THRESHOLD=2
[ "$(run_gate)" = "DEFER" ] && pass "threshold override=2 → level=2 defers (knob still works)" \
                            || fail "threshold override to 2 should make level=2 defer"
SYSTEM_PRESSURE_LEVEL_THRESHOLD="$OLD_T"

# 7. Gate disabled → never defer, even at critical
MOCK_LEVEL=4; MOCK_SWAP_FREE_M="100.00"
OLD_EN="$SYSTEM_PRESSURE_GATE_ENABLED"; SYSTEM_PRESSURE_GATE_ENABLED=false
[ "$(run_gate)" = "OK" ] && pass "SYSTEM_PRESSURE_GATE_ENABLED=false → never defers" \
                          || fail "disabled gate must not defer"
SYSTEM_PRESSURE_GATE_ENABLED="$OLD_EN"

# 8. Reason string is populated on defer, cleared on OK (callers log it)
MOCK_LEVEL=4; MOCK_SWAP_FREE_M="8192.00"; SYSTEM_PRESSURE_REASON=""
run_gate >/dev/null
[ -n "$SYSTEM_PRESSURE_REASON" ] && pass "SYSTEM_PRESSURE_REASON set on defer ('$SYSTEM_PRESSURE_REASON')" \
                                 || fail "reason must be set when deferring"
MOCK_LEVEL=1; MOCK_SWAP_FREE_M="8192.00"
run_gate >/dev/null
[ -z "$SYSTEM_PRESSURE_REASON" ] && pass "SYSTEM_PRESSURE_REASON cleared when OK" \
                                 || fail "reason must be empty when dispatching (got '$SYSTEM_PRESSURE_REASON')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
