#!/usr/bin/env bash
set -euo pipefail

# risk-approved-override-test.sh — Exercises the explicit [risk-approved] policy
# escape hatch. HIGH risk may be approved/armed only when the router sets the
# override, while UNKNOWN risk and unresolved review threads remain hard failures.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLICIES="$(cd "$SCRIPT_DIR/../pr-bot" && pwd)/pr_policies.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

log() { echo "[log] $*" >&2; }
ADO_BASE="https://ado.test/project"
ADO_ORG="org"

CALLS_FILE="$(mktemp)"
THREADS_MODE_FILE="$(mktemp)"
trap 'rm -f "$CALLS_FILE" "$THREADS_MODE_FILE"' EXIT
printf 'clean\n' > "$THREADS_MODE_FILE"

ado_api_call() {
  local url="$1" method="${2:-GET}" body="${3:-}"
  printf '%s %s %s\n' "$method" "$url" "$body" >> "$CALLS_FILE"

  if [[ "$url" == */_apis/connectionData ]]; then
    printf '{"authenticatedUser":{"id":"bot-id"}}\n'
    return 0
  fi
  if [[ "$url" == */threads?api-version=7.1 ]]; then
    if [[ "$(cat "$THREADS_MODE_FILE")" == "unresolved" ]]; then
      printf '{"value":[{"id":1,"status":"active","comments":[{"commentType":"text","content":"open"}]}]}\n'
    else
      printf '{"value":[]}\n'
    fi
    return 0
  fi
  return 0
}

# shellcheck source=../pr-bot/pr_policies.sh
source "$POLICIES"

reset_calls() { : > "$CALLS_FILE"; }
approval_cast() { grep -q 'PUT .*reviewers/bot-id.*"vote":10' "$CALLS_FILE"; }
autocomplete_armed() { grep -Fq '"autoCompleteSetBy"' "$CALLS_FILE"; }

# --- 1. HIGH without override is refused ---
reset_calls
if auto_approve_pr 3817 repo high 0 0 2>/dev/null; then
  fail "HIGH risk was approved without [risk-approved]"
else
  pass "HIGH risk refused without [risk-approved]"
fi
approval_cast && fail "unexpected approval vote without override" || pass "no approval vote without override"

reset_calls
if auto_complete_pr 3817 repo high 0 0 2>/dev/null; then
  fail "HIGH risk was auto-completed without [risk-approved]"
else
  pass "HIGH risk auto-complete refused without [risk-approved]"
fi
autocomplete_armed && fail "unexpected auto-complete without override" || pass "no auto-complete without override"

# --- 2. HIGH with override approves and arms when threads are clean ---
printf 'clean\n' > "$THREADS_MODE_FILE"
reset_calls
auto_approve_pr 3817 repo high 0 1 2>/dev/null \
  && pass "HIGH risk approved with explicit override" \
  || fail "HIGH risk was not approved with override"
approval_cast && pass "approval vote cast with override" || fail "approval vote missing with override"

reset_calls
auto_complete_pr 3817 repo high 0 1 2>/dev/null \
  && pass "HIGH risk auto-complete armed with override" \
  || fail "HIGH risk auto-complete failed with override"
autocomplete_armed && pass "auto-complete PATCH sent with override" || fail "auto-complete PATCH missing with override"

# --- 3. Override cannot bypass unresolved review threads ---
printf 'unresolved\n' > "$THREADS_MODE_FILE"
reset_calls
if auto_complete_pr 3817 repo high 0 1 2>/dev/null; then
  fail "override bypassed an unresolved review thread"
else
  pass "override still refuses unresolved review threads"
fi
autocomplete_armed && fail "auto-complete armed with an unresolved thread" || pass "no auto-complete with unresolved thread"

# --- 4. UNKNOWN risk remains fail-closed even with override ---
reset_calls
if auto_approve_pr 3817 repo unknown 0 1 2>/dev/null; then
  fail "UNKNOWN risk was approved via override"
else
  pass "UNKNOWN risk refuses approval even with override"
fi
approval_cast && fail "approval vote cast for UNKNOWN risk" || pass "no approval vote for UNKNOWN risk"

reset_calls
if auto_complete_pr 3817 repo unknown 0 1 2>/dev/null; then
  fail "UNKNOWN risk was auto-completed via override"
else
  pass "UNKNOWN risk refuses auto-complete even with override"
fi
autocomplete_armed && fail "auto-complete armed for UNKNOWN risk" || pass "no auto-complete for UNKNOWN risk"

# --- 5. [no-auto] remains dominant over the risk override ---
reset_calls
if auto_approve_pr 3817 repo high 1 1 2>/dev/null; then
  fail "[no-auto] did not suppress approval"
else
  pass "[no-auto] still suppresses approval with override"
fi
reset_calls
if auto_complete_pr 3817 repo high 1 1 2>/dev/null; then
  fail "[no-auto] did not suppress auto-complete"
else
  pass "[no-auto] still suppresses auto-complete with override"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
