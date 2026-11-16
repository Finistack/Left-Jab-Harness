#!/usr/bin/env bash
# Offline regression: Authorization must arrive via stdin, never curl argv.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
export TEST_TMP="$TMP"
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env python3
import sys,os,json,pathlib
args=sys.argv[1:]; header=sys.stdin.read()
expected='Authorization: '+os.environ['TEST_AUTH']+'\n'
assert header==expected, 'Authorization missing from stdin'
assert os.environ['TEST_AUTH'] not in ' '.join(args), 'Credential in argv'
assert 'Authorization:' not in ' '.join(args), 'Header in argv'
assert args[args.index('-H')+1]=='@-'
if os.environ.get('TEST_METHOD')=='POST':
 assert args[args.index('-X')+1]=='POST'
 assert args[args.index('-d')+1]=='{"message":"fixture"}'
p=pathlib.Path(os.environ['TEST_TMP'])/'calls'
n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n))
pathlib.Path(args[args.index('-o')+1]).write_text('{"ok":true}')
if os.environ.get('TEST_RETRY')=='yes' and n==1: print('500',end='')
else: print(os.environ.get('TEST_STATUS','200'),end='')
CURL
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
# shellcheck source=../shared/ado_api.sh
source "$ROOT/src/build/shared/ado_api.sh"
export TEST_AUTH='Basic SYNTHETIC_AUTH_SENTINEL'
# Invoked indirectly by the sourced helper.
# shellcheck disable=SC2317
get_ado_auth_header_cached() { printf '%s' "$TEST_AUTH"; }
sleep() { :; }
export TEST_METHOD=GET
[[ "$(ado_get https://example.invalid/api)" == '{"ok":true}' ]]
export TEST_METHOD=POST
[[ "$(ado_post https://example.invalid/api '{"message":"fixture"}')" == '{"ok":true}' ]]
rm "$TMP/calls"
export TEST_RETRY=yes TEST_METHOD=GET
[[ "$(ado_get https://example.invalid/api 2>/dev/null)" == '{"ok":true}' ]]
[[ "$(cat "$TMP/calls")" == 2 ]]
unset TEST_RETRY
export TEST_STATUS=401
if ado_get https://example.invalid/api >/dev/null 2>&1; then echo 'auth failure unexpectedly succeeded'; exit 1; fi
unset TEST_STATUS
# Preserve the PAT fallback path without placing its header in argv.
get_ado_auth_header_cached() { return 1; }
export ADO_PAT=FAKE_PAT_SENTINEL
TEST_AUTH="Basic $(printf ':FAKE_PAT_SENTINEL' | base64 | tr -d '\n')"; export TEST_AUTH
[[ "$(ado_get https://example.invalid/api)" == '{"ok":true}' ]]
# Exercise the actual startup health-check request without its unrelated cleanup.
# Match the literal variable name in source, not this test environment.
# shellcheck disable=SC2016
health_request=$(sed -n '/^periodic_health_check() {/,/^  if \[\[ "$ado_code"/p' "$ROOT/src/build/pr-bot/start.sh" | sed '$d')
eval "$health_request
}"
export ADO_ORG=fixture
periodic_health_check
echo 'PASS: GET, POST/body, retry, auth failure, fallback, startup health check; headers on stdin and absent from argv' 
