#!/usr/bin/env bash
set -euo pipefail

# renovate-config-test.sh — Guard the harness image's Renovate coverage.
#
# The runtime image's build-time toolchain is pinned in src/build/pr-bot/Dockerfile.
# Renovate keeps those pins current only if BOTH hold:
#   1. the '# renovate:' annotations on the ARG lines parse with the regex in
#      renovate.json's customManager (the built-in dockerfile manager reads only
#      FROM lines, so the ARG pins need this custom manager), and
#   2. no toolchain ARG floats at 'latest', which Renovate cannot meaningfully track.
#
# The extraction is exercised with the SHIPPED regex from renovate.json (not a copy),
# so the check fails if either side drifts.

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DOCKERFILE="$REPO_ROOT/src/build/pr-bot/Dockerfile"
RENOVATE_JSON="$REPO_ROOT/renovate.json"

[ -f "$DOCKERFILE" ] || { echo "FAIL: missing $DOCKERFILE"; exit 1; }
[ -f "$RENOVATE_JSON" ] || { echo "FAIL: missing $RENOVATE_JSON"; exit 1; }

python3 - "$DOCKERFILE" "$RENOVATE_JSON" <<'PY'
import json
import re
import sys

dockerfile_path, renovate_path = sys.argv[1], sys.argv[2]
dockerfile = open(dockerfile_path).read()
config = json.load(open(renovate_path))

regex_managers = [m for m in config.get("customManagers", []) if m.get("customType") == "regex"]
if not regex_managers:
    print("FAIL: renovate.json has no custom.regex customManager for the Dockerfile ARG pins")
    sys.exit(1)

pattern = regex_managers[0]["matchStrings"][0]
compiled = re.compile(pattern.replace("(?<", "(?P<"))
found = {m.group("depName"): m.group("currentValue") for m in compiled.finditer(dockerfile)}

failures = 0
for dep in ("node", "@anthropic-ai/claude-code"):
    if dep in found:
        print(f"PASS: Renovate extracts {dep} = {found[dep]}")
    else:
        print(f"FAIL: Renovate cannot extract the '{dep}' pin from the Dockerfile")
        failures += 1

for name, value in re.findall(r"^ARG\s+(\w+)=(\S+)", dockerfile, re.MULTILINE):
    if value.lower() == "latest":
        print(f"FAIL: ARG {name} floats at 'latest'; pin it so Renovate can track it")
        failures += 1

sys.exit(1 if failures else 0)
PY

echo "renovate-config-test OK"
