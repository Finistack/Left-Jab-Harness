#!/usr/bin/env bash
set -euo pipefail

# github-pr-review-test.sh — Unit test for the GitHub PR-review poster's PURE
# functions (no network). Like the other suites it exercises the REAL shipped
# code, but the poster is Python, so this harness shells to `python3`, loads the
# hyphenated module by path (importlib), and asserts the pure helpers.
#
# Pins the fidelity-critical behaviors ported from the ADO poster:
#   * severity → label map (critical/warning/info → [HIGH]/[MED]/[LOW], default [LOW])
#   * normalize_comment strips header + severity prefix + (`path:line`) marker
#   * build_comment_body / normalize_comment round-trip (dedup symmetry)
#   * normalize_path lstrip('/')  (inverse of the ADO poster's prepend)
#   * Claude output envelope: bare array, fenced result, single dict, garbage → []
#   * parse_fallback_location recovers (path, line) from a fallback note
#   * is_duplicate_comment symmetry across inline vs fallback formatting
#   * select_threads_to_resolve: human reply resolves; unknown bot is fail-safe
#
# Auto-discovered by the CI `for t in src/build/test/*.sh` loop.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POSTER="$(cd "$SCRIPT_DIR/.." && pwd)/github-pr-review.py"

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$POSTER" ]; then
  echo "❌ Cannot find github-pr-review.py at $POSTER"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "⚠️  python3 not found — skipping GitHub poster unit tests"
  exit 0
fi

echo "🧪 GitHub PR-review poster — pure-function tests"
echo "   module: $POSTER"
echo ""

# --- Syntax guard: the module must compile (first Python in the repo). This is a
# hard precondition — if it doesn't compile, importlib can't load it below. ---
if python3 -m py_compile "$POSTER" 2>/tmp/ghpr-pycompile.log; then
  pass "py_compile (syntax guard)"
else
  fail "py_compile failed: $(cat /tmp/ghpr-pycompile.log)"
  echo ""
  echo "Results: $PASS passed, $((FAIL)) failed"
  exit 1
fi

# --- Drive the pure functions in a single python3 process. It prints one
# "OK <name>" or "FAIL <name> <detail>" line per assertion; we translate those
# into this suite's pass/fail counters so a Python regression fails the stage. ---
RESULTS="$(POSTER_PATH="$POSTER" python3 <<'PYEOF'
import importlib.util, json, os

spec = importlib.util.spec_from_file_location("ghpr", os.environ["POSTER_PATH"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def check(name, cond, detail=""):
    print(f"OK {name}" if cond else f"FAIL {name} {detail}")

# severity map
check("sev_critical", m.severity_label("critical") == "[HIGH]")
check("sev_warning", m.severity_label("warning") == "[MED]")
check("sev_info", m.severity_label("info") == "[LOW]")
check("sev_default", m.severity_label("nonsense") == "[LOW]")

# path normalization (lstrip — inverse of ADO)
check("path_strip_leading", m.normalize_path("/src/a.py") == "src/a.py")
check("path_noop", m.normalize_path("src/a.py") == "src/a.py")
check("path_empty", m.normalize_path("") == "")

# body build + normalize round-trip
body = m.build_comment_body("critical", "Null deref here")
check("body_format", body == "[HIGH] **[Claude Review - CRITICAL]**\n\nNull deref here", repr(body))
check("normalize_strips_header_sev", m.normalize_comment(body) == "Null deref here", repr(m.normalize_comment(body)))

# fallback location marker: build, parse, and normalize away
fb = m.build_comment_body("info", "Oops", location="README.md:99999")
check("fallback_has_marker", "(`README.md:99999`)" in fb, repr(fb))
check("parse_fallback_path_line", m.parse_fallback_location(fb) == ("README.md", 99999), str(m.parse_fallback_location(fb)))
check("parse_fallback_path_only", m.parse_fallback_location("x (`README.md`) y") == ("README.md", None))
check("parse_fallback_none", m.parse_fallback_location("no marker") == (None, None))
check("normalize_strips_location", m.normalize_comment(fb) == "Oops", repr(m.normalize_comment(fb)))

# check_id extraction + embedding
cbody = m.build_comment_body("warning", "x", check_id="helm-sync:1")
check("check_id_extract", m.extract_check_id(cbody) == "helm-sync:1")
check("check_id_none", m.extract_check_id("no marker here") is None)

# Claude output envelope
check("env_bare_array", m.extract_review_from_claude_output("[]") == [])
fenced = json.dumps({"result": "```json\n[{\"comment\":\"x\",\"file\":\"a.py\",\"line\":3}]\n```"})
check("env_fenced_result", m.extract_review_from_claude_output(fenced) == [{"comment": "x", "file": "a.py", "line": 3}])
check("env_single_dict", m.extract_review_from_claude_output(json.dumps({"comment": "solo"})) == [{"comment": "solo"}])
check("env_result_nonjson", m.extract_review_from_claude_output(json.dumps({"result": "not json at all"})) == [])
try:
    m.extract_review_from_claude_output("total garbage")
    check("env_garbage_raises", False, "did not raise")
except (json.JSONDecodeError, ValueError):
    check("env_garbage_raises", True)

# dedup symmetry: inline body vs raw comment, with / without leading slash
sigs = set()
sigs.add((m.normalize_path("a.py"), m.normalize_comment(m.build_comment_body("warning", "dup issue"))))
check("dedup_raw", m.is_duplicate_comment("a.py", "dup issue", sigs))
check("dedup_formatted", m.is_duplicate_comment("/a.py", "[MED] **[Claude Review - WARNING]**\n\ndup issue", sigs))
check("dedup_negative", not m.is_duplicate_comment("a.py", "different issue", sigs))

# build_signatures over a GraphQL thread + a PR-level fallback note
threads = [{
    "id": "T1", "isResolved": False, "path": "src/x.py",
    "body": m.build_comment_body("critical", "inline finding"),
    "comments": [{"databaseId": 11, "body": m.build_comment_body("critical", "inline finding"),
                  "path": "src/x.py", "author_login": "bot"}],
}]
issue_comments = [{"id": 22, "author_login": "bot",
                   "body": m.build_comment_body("info", "fallback finding", location="src/y.py:42")}]
reviewed, sig2 = m.build_signatures(threads, issue_comments)
check("sig_reviewed_files", reviewed == {"src/x.py"}, str(reviewed))
check("sig_inline_present", ("src/x.py", "inline finding") in sig2, str(sig2))
check("sig_fallback_present", ("src/y.py", "fallback finding") in sig2, str(sig2))

# auto-resolve selection: human reply resolves; bot-only does not; unknown bot fail-safe
human_thread = {"id": "H", "isResolved": False,
                "comments": [{"body": "[Claude Review x", "author_login": "review-bot"},
                             {"body": "thanks, fixed", "author_login": "alice"}]}
bot_only = {"id": "B", "isResolved": False,
            "comments": [{"body": "[Claude Review y", "author_login": "review-bot"},
                         {"body": "bot note", "author_login": "review-bot"}]}
check("resolve_human_reply", m.select_threads_to_resolve([human_thread, bot_only], "review-bot") == ["H"])
check("resolve_unknown_botsafe", m.select_threads_to_resolve([human_thread], "") == [])
PYEOF
)"

echo "$RESULTS" | while IFS= read -r line; do
  case "$line" in
    "OK "*)   pass "${line#OK }" ;;
    "FAIL "*) fail "${line#FAIL }" ;;
  esac
done

# The while-loop above runs in a subshell (pipe), so re-derive counts from output
# for the authoritative exit status.
PASS=$(echo "$RESULTS" | grep -c '^OK ' || true)
FAIL=$(echo "$RESULTS" | grep -c '^FAIL ' || true)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
