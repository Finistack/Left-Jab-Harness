#!/usr/bin/env bash
set -euo pipefail

# insteadof-strip-test.sh — Unit test for strip_hostile_insteadof() in
# setup-git-credentials.sh, run against a REAL throwaway git repo (no network).
#
# Like orphan-reaper-test.sh / pressure-gate-test.sh, we extract the REAL shipped
# function out of setup-git-credentials.sh (counted-brace awk parser, so nested
# col-0 '}' don't truncate) and exercise it — never a copy.
#
# The regression this pins: a leftover repo-LOCAL rewrite rule
#   url."git@ssh.dev.azure.com:v3/org/proj/".insteadOf = "https://dev.azure.com/org/proj/_git/"
# makes git silently rewrite the HTTPS origin onto SSH on *every* op. Under the
# systemd --user service there is no SSH agent, so `git ls-remote origin` then
# fails with a misleading "PAT may be broken" and the bot wedges. The old
# self-heal looped forever because `git remote get-url origin` resolves *through*
# insteadOf and always reported SSH. strip_hostile_insteadof physically removes
# exactly those ADO-HTTPS→SSH rules and nothing else.
#
# Assertions:
#   A1  origin resolves to HTTPS == raw remote.origin.url (rewrite is gone)
#   A2  hostile ADO-SSH insteadOf (incl. its multivar 2nd value) removed
#   A3  hostile vs-ssh pushInsteadOf removed
#   A4  benign github SSH insteadOf preserved (non-ADO base)
#   A5  benign ADO https→https insteadOf preserved (HTTPS base, not SSH)
#   A6  origin-ssh backup remote left intact
#   A7  second run is a silent no-op (idempotent), origin stays HTTPS
#   A8  clean repo (no insteadOf at all) → silent, rc 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SH="$(cd "$SCRIPT_DIR/.." && pwd)/setup-git-credentials.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SETUP_SH" ]; then
  echo "❌ Cannot find setup-git-credentials.sh at $SETUP_SH"
  exit 1
fi

# Hermetic git: ignore the host's GLOBAL/SYSTEM config (esp. any developer
# insteadOf rules) so resolution depends ONLY on the repo-local config we set.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# --- Extract the REAL function from setup-git-credentials.sh (counted-brace
# parser; balanced ${...} expansions net to zero depth so they don't truncate) ---
extract_fn() {
  awk -v fn="$1" '
    !found && $0 ~ "^"fn"\\(\\) \\{" { found=1; depth=0 }
    found {
      s=$0; depth += gsub(/{/,"{",s); s=$0; depth -= gsub(/}/,"}",s)
      print
      if (found && depth == 0) exit
    }
  ' "$SETUP_SH"
}

body="$(extract_fn strip_hostile_insteadof)"
if [ -z "$body" ]; then
  echo "❌ Failed to extract function 'strip_hostile_insteadof' from setup-git-credentials.sh"
  exit 1
fi
eval "$body"

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

RAW_HTTPS="https://dev.azure.com/finistack/Finistack/_git/Finistack"
SSH_BACKUP="git@ssh.dev.azure.com:v3/finistack/Finistack/Finistack"

# --- Build a throwaway target repo that reproduces the wedge --------------------
REPO="$TMPROOT/target"
git init -q "$REPO"
git -C "$REPO" remote add origin "$RAW_HTTPS"
# origin-ssh backup remote (the install flow stashes the SSH URL here — must survive)
git -C "$REPO" remote add origin-ssh "$SSH_BACKUP"

# HOSTILE #1 — ADO-SSH base, ADO-HTTPS value, with a 2nd (multivar) ADO-HTTPS value
git -C "$REPO" config --local \
  'url.git@ssh.dev.azure.com:v3/finistack/Finistack/.insteadOf' \
  'https://dev.azure.com/finistack/Finistack/_git/'
git -C "$REPO" config --local --add \
  'url.git@ssh.dev.azure.com:v3/finistack/Finistack/.insteadOf' \
  'https://finistack.visualstudio.com/Finistack/_git/'

# HOSTILE #2 — vs-ssh base, ADO-HTTPS value, via pushInsteadOf
git -C "$REPO" config --local \
  'url.finistack@vs-ssh.visualstudio.com:v3/finistack/Finistack/.pushInsteadOf' \
  'https://finistack.visualstudio.com/Finistack/_git/'

# BENIGN #1 — github SSH convenience rule (non-ADO base → must be preserved)
git -C "$REPO" config --local \
  'url.git@github.com:.insteadOf' \
  'https://github.com/'

# BENIGN #2 — ADO https→https normalization (HTTPS base, not SSH → must be preserved)
git -C "$REPO" config --local \
  'url.https://dev.azure.com/finistack/Finistack/_git/.insteadOf' \
  'https://dev.azure.com/finistack/FinistackMirror/_git/'

echo "🧪 strip_hostile_insteadof test (real repo, no network)"
echo "   repo: $REPO"
echo ""

# Precondition: the hostile rule must actually be biting (origin → SSH) BEFORE the
# strip, otherwise the test would pass vacuously.
pre_resolved="$(git -C "$REPO" remote get-url origin)"
if [ "$pre_resolved" != "$SSH_BACKUP" ]; then
  echo "❌ Setup failed to reproduce the wedge: origin resolved to '$pre_resolved'"
  echo "   expected SSH rewrite '$SSH_BACKUP'"
  exit 1
fi
echo "   precondition OK — before strip, origin resolves to SSH: $pre_resolved"
echo ""

# --- Run the REAL function ------------------------------------------------------
strip_out="$(strip_hostile_insteadof "$REPO" 2>&1)" && strip_rc=0 || strip_rc=$?
[ -n "$strip_out" ] && echo "$strip_out"
[ "$strip_rc" -eq 0 ] || fail "strip_hostile_insteadof returned rc=$strip_rc (contract: always 0)"

# A1 — origin now resolves to HTTPS, equal to the raw local URL
raw="$(git -C "$REPO" config --local remote.origin.url 2>/dev/null || true)"
resolved="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
if [ "$resolved" = "$raw" ] && [ "$resolved" = "$RAW_HTTPS" ]; then
  pass "A1 origin resolves to HTTPS, == raw ($resolved)"
else
  fail "A1 origin resolved='$resolved' raw='$raw' (expected both == $RAW_HTTPS)"
fi

# A2 — hostile ADO-SSH insteadOf (both multivar values) removed
h1="$(git -C "$REPO" config --local --get-all 'url.git@ssh.dev.azure.com:v3/finistack/Finistack/.insteadOf' 2>/dev/null || true)"
if [ -z "$h1" ]; then
  pass "A2 hostile ADO-SSH insteadOf removed (incl. multivar 2nd value)"
else
  fail "A2 ADO-SSH insteadOf still present: [$h1]"
fi

# A3 — hostile vs-ssh pushInsteadOf removed
h2="$(git -C "$REPO" config --local --get-all 'url.finistack@vs-ssh.visualstudio.com:v3/finistack/Finistack/.pushInsteadOf' 2>/dev/null || true)"
if [ -z "$h2" ]; then
  pass "A3 hostile vs-ssh pushInsteadOf removed"
else
  fail "A3 vs-ssh pushInsteadOf still present: [$h2]"
fi

# A4 — benign github SSH rule preserved
g="$(git -C "$REPO" config --local --get-all 'url.git@github.com:.insteadOf' 2>/dev/null || true)"
if [ "$g" = "https://github.com/" ]; then
  pass "A4 github SSH insteadOf preserved (non-ADO base untouched)"
else
  fail "A4 github rule got mangled: [$g]"
fi

# A5 — benign ADO https→https rule preserved (HTTPS base, not SSH)
hh="$(git -C "$REPO" config --local --get-all 'url.https://dev.azure.com/finistack/Finistack/_git/.insteadOf' 2>/dev/null || true)"
if [ "$hh" = "https://dev.azure.com/finistack/FinistackMirror/_git/" ]; then
  pass "A5 ADO https→https insteadOf preserved (HTTPS base, not forced onto SSH)"
else
  fail "A5 https→https rule got mangled: [$hh]"
fi

# A6 — origin-ssh backup remote intact
ossh="$(git -C "$REPO" config --local --get remote.origin-ssh.url 2>/dev/null || true)"
if [ "$ossh" = "$SSH_BACKUP" ]; then
  pass "A6 origin-ssh backup remote intact ($ossh)"
else
  fail "A6 origin-ssh backup remote changed: [$ossh]"
fi

# A7 — second run is a silent no-op (idempotent), origin stays HTTPS
strip_out2="$(strip_hostile_insteadof "$REPO" 2>&1)" && rc2=0 || rc2=$?
resolved2="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
if [ "$rc2" -eq 0 ] && [ -z "$strip_out2" ] && [ "$resolved2" = "$RAW_HTTPS" ]; then
  pass "A7 idempotent — 2nd run silent (rc 0), origin still HTTPS"
else
  fail "A7 not a clean no-op (rc=$rc2, out='$strip_out2', origin='$resolved2')"
fi

# A8 — clean repo (no insteadOf rules at all) → silent, rc 0
CLEAN="$TMPROOT/clean"
git init -q "$CLEAN"
git -C "$CLEAN" remote add origin "$RAW_HTTPS"
clean_out="$(strip_hostile_insteadof "$CLEAN" 2>&1)" && crc=0 || crc=$?
if [ "$crc" -eq 0 ] && [ -z "$clean_out" ]; then
  pass "A8 clean repo → silent, rc 0"
else
  fail "A8 clean repo not silent/zero (rc=$crc, out='$clean_out')"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
