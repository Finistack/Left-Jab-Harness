#!/usr/bin/env bash
set -euo pipefail

# risk-classify-model-test.sh — Pins the risk classifier's model selection and its
# loud-on-failure observability, the two behaviours that previously fail-closed every
# PR silently:
#   * classify_pr_risk MUST pass --model "$ANTHROPIC_SMALL_FAST_MODEL" when that var is
#     set (the heavy ANTHROPIC_MODEL default is what some proxies reject with HTTP 400,
#     collapsing risk to "unknown"), and MUST omit --model when it is unset so plain
#     deployments keep inheriting the default.
#   * On a claude failure it MUST emit a loud diagnostic on STDERR (so the journal shows
#     WHY) while keeping STDOUT a clean unknown-risk JSON (the caller captures stdout as
#     risk_json — a leaked log line there would corrupt the parse).
#
# We source the REAL shipped pr_policies.sh (a pure function library, no top-level side
# effects) and drive classify_pr_risk with a mocked claude/timeout, mirroring the
# extract-and-exercise approach of the other suites.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLICIES="$(cd "$SCRIPT_DIR/../pr-bot" && pwd)/pr_policies.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$POLICIES" ]; then
  echo "❌ Cannot find pr_policies.sh at $POLICIES"
  exit 1
fi

# Mocks on classify_pr_risk's call path. `command -v claude` must report success so the
# real code takes the claude branch; `timeout` drops its duration arg and execs the rest;
# `git` is a no-op (empty work_dir → empty diff, still classifies); `log` is captured by
# the test via stderr redirection at each call site.
log()     { echo "[log] $*"; }
git()     { return 0; }
timeout() { shift; "$@"; }
command() {
  if [ "${1:-}" = "-v" ] && [ "${2:-}" = "claude" ]; then echo "claude"; return 0; fi
  builtin command "$@"
}

# shellcheck source=../pr-bot/pr_policies.sh
source "$POLICIES"

ARGS_FILE="$(mktemp)"
trap 'rm -f "$ARGS_FILE"' EXIT

# --- 1. small/fast model SET → real risk returned, --model passed through ---
claude() { printf '%s\n' "$*" > "$ARGS_FILE"; echo '{"risk":"low","reasoning":"docs only"}'; }
export ANTHROPIC_SMALL_FAST_MODEL="test-small-fast"
out="$(classify_pr_risk 1 repo "" 2>/dev/null)"
echo "$out" | jq -e '.risk == "low"' >/dev/null 2>&1 \
  && pass "small/fast set → real risk returned (low, not unknown)" \
  || fail "expected risk=low, got: $out"
grep -q -- "--model test-small-fast" "$ARGS_FILE" \
  && pass "claude invoked WITH --model test-small-fast" \
  || fail "--model not passed. args=[$(cat "$ARGS_FILE")]"
grep -q -- "--print" "$ARGS_FILE" \
  && pass "claude still invoked with --print (contract preserved)" \
  || fail "--print missing. args=[$(cat "$ARGS_FILE")]"

# --- 2. model UNSET → --model omitted (inherit the deployment default) ---
unset ANTHROPIC_SMALL_FAST_MODEL
: > "$ARGS_FILE"
classify_pr_risk 1 repo "" >/dev/null 2>&1
if grep -q -- "--model" "$ARGS_FILE"; then
  fail "--model must be absent when ANTHROPIC_SMALL_FAST_MODEL unset. args=[$(cat "$ARGS_FILE")]"
else
  pass "model unset → --model omitted (no hardcoded alias)"
fi

# --- 3. claude FAILS → loud line on STDERR, clean unknown JSON on STDOUT ---
claude() { echo "API Error: 400 model is not available" >&2; return 1; }
export ANTHROPIC_SMALL_FAST_MODEL="bogus-alias"
err_file="$(mktemp)"
out="$(classify_pr_risk 1 repo "" 2>"$err_file")"
err="$(cat "$err_file")"; rm -f "$err_file"
echo "$out" | jq -e '.risk == "unknown"' >/dev/null 2>&1 \
  && pass "failure → stdout is clean unknown-risk JSON" \
  || fail "stdout not clean unknown JSON: $out"
echo "$err" | grep -q "risk-classify: claude failed (rc=1)" \
  && pass "failure → loud diagnostic emitted (rc + reason)" \
  || fail "missing loud diagnostic. stderr=[$err]"
echo "$err" | grep -q "model is not available" \
  && pass "failure → stderr snippet from claude included" \
  || fail "stderr snippet not surfaced. stderr=[$err]"
if echo "$out" | grep -q "risk-classify"; then
  fail "loud line LEAKED into stdout JSON (would corrupt risk_json parse)"
else
  pass "loud line kept OFF stdout (risk_json stays parseable)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
