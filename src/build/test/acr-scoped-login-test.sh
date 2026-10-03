#!/usr/bin/env bash
set -euo pipefail

# acr-scoped-login-test.sh — Regression test for the ACR-scoped login helper.
#
# The finistackproduction ACR has "ARM audience token authentication" disabled
# (workload-hardening policy 42781ec6, the MDC control). The Docker@2 task's
# docker-registry service-connection login is ARM-scoped and now 401s, so the
# harness pipeline pushes with src/build/acr-scoped-login.sh instead. This test
# extracts and exercises the SHIPPED helper with stubbed az/docker, so a future
# edit that reintroduces the ARM login or breaks the scoped flow fails here.

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
helper="$repo_root/src/build/acr-scoped-login.sh"
fixture="$(mktemp -d /tmp/finistack-acr-test.XXXXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"

[ -f "$helper" ] || { echo "FAIL: missing $helper"; exit 1; }

cat > "$fixture/bin/az" <<'AZ'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'account show')
    [[ " $* " == *' --query id --output tsv '* ]] || exit 72
    printf '%s\n' '7e49f3c7-4e19-460a-8405-1d608b87aebc'
    ;;
  'login --service-principal')
    [[ "$AZURE_CONFIG_DIR" == /tmp/finistack-acr-auth.*/azure ]] || exit 73
    [[ "$DOCKER_CONFIG" == /tmp/finistack-acr-auth.*/docker ]] || exit 74
    [[ " $* " == *' --scope https://containerregistry.azure.net/.default --output none '* ]] || exit 75
    printf 'login\n' >> "$MOCK_LOG"
    printf '%s\n' "$MOCK_TOKEN" > "$AZURE_CONFIG_DIR/accessToken.json"
    ;;
  'account set')
    printf 'subscription\n' >> "$MOCK_LOG"
    ;;
  'acr login')
    [[ " $* " == *' --name finistackproduction --output none '* ]] || exit 80
    printf 'acr\n' >> "$MOCK_LOG"
    printf '%s\n' "$MOCK_TOKEN" > "$DOCKER_CONFIG/config.json"
    ;;
  *) exit 81 ;;
esac
AZ

cat > "$fixture/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == push ]] || exit 82
[[ -f "$DOCKER_CONFIG/config.json" ]] || exit 84
printf 'push %s\n' "$2" >> "$MOCK_LOG"
DOCKER
chmod +x "$fixture/bin/az" "$fixture/bin/docker"

case_dir="$fixture/case"
mkdir -p "$case_dir"
export PATH="$fixture/bin:$PATH"
export AGENT_TEMP="$case_dir/agenttemp"
export AZURE_CONFIG_DIR="$AGENT_TEMP/bootstrap"
mkdir -p "$AZURE_CONFIG_DIR"
export MOCK_LOG="$case_dir/events"
export MOCK_TOKEN="synthetic-secret"
export servicePrincipalId='synthetic-client-id'
export tenantId='synthetic-tenant-id'
export idToken="$MOCK_TOKEN"

bash -c '
  set -euo pipefail
  source "$1"
  acr_scoped_login
  docker push finistackproduction.azurecr.io/left-jab-harness:1.0.test
' bash "$helper" > "$case_dir/output" 2>&1

events="$(paste -sd, - < "$MOCK_LOG")"
[[ "$events" == "login,subscription,acr,push finistackproduction.azurecr.io/left-jab-harness:1.0.test" ]] \
  || { echo "FAIL: unexpected auth/push order: $events"; exit 1; }

! grep -R -Fq -- "$MOCK_TOKEN" "$case_dir/output" || { echo "FAIL: token escaped to output"; exit 1; }

echo "acr-scoped-login-test OK"
