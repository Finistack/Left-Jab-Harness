#!/usr/bin/env bash
# Persistent-agent hygiene for trusted CI jobs. This is not a sandbox for untrusted PRs.
set -euo pipefail

fail() { echo "CI preflight: $*" >&2; exit 1; }

prepare() {
  [[ "$(uname -s)" == Linux ]] || fail 'a Linux agent is required'
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) \
    || fail 'Bash 4.3 or newer is required'
  local kind="$1" tool root
  local -a required=(git python3)
  case "$kind" in
    lint) required+=(shellcheck jq) ;;
    build) required+=(docker az) ;;
    review) ;;
    *) fail "unknown job kind: $kind" ;;
  esac
  for tool in "${required[@]}"; do
    command -v "$tool" >/dev/null || fail "missing $tool; provision the agent before running CI"
  done
  if [[ "$kind" == build ]]; then
    # Inherit the assigned agent's endpoint. Never fall back to the shared system daemon.
    [[ -z "${DOCKER_CONTEXT:-}" ]] || fail 'DOCKER_CONTEXT would override the assigned socket'
    [[ "${DOCKER_HOST:-}" == unix:///* ]] || fail 'DOCKER_HOST must select the assigned private Unix socket'
    python3 - <<'PY'
import os
import pathlib
import stat

socket = pathlib.Path(os.environ['DOCKER_HOST'][7:]).resolve()
work = pathlib.Path(os.environ['AGENT_WORKFOLDER']).resolve()
slot = work.parent
if socket in (pathlib.Path('/run/docker.sock'), pathlib.Path('/var/run/docker.sock').resolve()):
    raise SystemExit('CI preflight: refusing the shared system Docker socket')
if slot == pathlib.Path('/'):
    raise SystemExit('CI preflight: agent slot root cannot be /')
try:
    socket.relative_to(slot)
except ValueError:
    raise SystemExit('CI preflight: Docker socket must belong to the assigned agent work-folder parent')
if not stat.S_ISSOCK(socket.stat().st_mode):
    raise SystemExit('CI preflight: assigned Docker endpoint is not a Unix socket')
PY
    docker info --format '{{.ServerVersion}}' >/dev/null
  fi
  umask 077
  root=$(mktemp -d "${AGENT_TEMPDIRECTORY:?}/harness-ci.XXXXXXXX")
  printf '%s\n' "${SYSTEM_JOBID:?}" > "$root/.job-id"
  [[ "$kind" != build ]] || printf '%s\n' "$DOCKER_HOST" > "$root/.docker-host"
  mkdir "$root/docker" "$root/cli" "$root/npm-cache" "$root/claude"
  printf '##vso[task.setvariable variable=ciJobDir]%s\n' "$root"
}

check_node() {
  [[ "$(node -p 'process.versions.node.split(".")[0]')" == 20 ]] \
    || fail 'UseNode must select Node.js 20.x before installing the review CLI'
}

owned_job_dir() {
  [[ -n "${CI_JOB_DIR:-}" && -d "$CI_JOB_DIR" ]] || return 1
  local job_name="${CI_JOB_DIR##*/}"
  # Shell wildcard * also matches /. Require exactly one child path component.
  [[ "$CI_JOB_DIR" == "${AGENT_TEMPDIRECTORY:?}/$job_name" && "$job_name" == harness-ci.?* ]] \
    || fail 'refusing cleanup outside a direct job temporary directory'
  [[ ! -L "$CI_JOB_DIR" && -f "$CI_JOB_DIR/.job-id" ]] || fail 'missing job ownership marker'
  [[ "$(cat "$CI_JOB_DIR/.job-id")" == "${SYSTEM_JOBID:?}" ]] || fail 'job ownership mismatch'
}

image_id_or_absent() {
  local ref="$1" image_id error_text
  local error_file="${CI_JOB_DIR:?}/docker-inspect.stderr"
  if image_id=$(LC_ALL=C docker image inspect --format '{{.Id}}' "$ref" 2>"$error_file"); then
    [[ -n "$image_id" ]] || { echo "CI cleanup: inspect returned no ID for $ref" >&2; return 1; }
    printf '%s\n' "$image_id"
    return 0
  fi
  error_text=$(<"$error_file")
  # Only a definite absence is a successful empty result. Unknown/combined errors fail closed.
  case "$error_text" in
    "Error response from daemon: No such image: $ref"|"Error: No such image: $ref") return 0 ;;
  esac
  printf 'CI cleanup: failed to inspect image %s\n%s\n' "$ref" "$error_text" >&2
  return 1
}

cleanup_image() {
  # A failed preflight must not even query a default/shared Docker daemon in cleanup.
  owned_job_dir || return 0
  [[ -f "$CI_JOB_DIR/.docker-host" ]] || return 0
  [[ "$(cat "$CI_JOB_DIR/.docker-host")" == "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]] \
    || fail 'Docker endpoint changed since preflight'
  local image_id ref ref_id failed=0
  local -a refs=()
  # The unique local ref is the ownership record. Never remove by ID or prune a daemon.
  image_id=$(image_id_or_absent "${LOCAL_IMAGE:?}") || return 1
  [[ -n "$image_id" ]] || return 0
  if [[ -f "$CI_JOB_DIR/published-image-refs" ]]; then
    mapfile -t refs < "$CI_JOB_DIR/published-image-refs"
  fi
  refs+=("$LOCAL_IMAGE")
  for ref in "${refs[@]}"; do
    ref_id=$(image_id_or_absent "$ref") || { failed=1; continue; }
    if [[ "$ref_id" == "$image_id" ]]; then
      docker image rm "$ref" || failed=1
    fi
  done
  return "$failed"
}

cleanup() {
  owned_job_dir || return 0
  rm -rf -- "$CI_JOB_DIR"
}

case "${1:-}" in
  prepare) prepare "${2:?job kind required}" ;;
  check-node) check_node ;;
  cleanup-image) cleanup_image ;;
  cleanup) cleanup ;;
  *) fail 'usage: ci-job.sh {prepare lint|build|review|check-node|cleanup-image|cleanup}' ;;
esac
