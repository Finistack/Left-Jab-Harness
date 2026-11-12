#!/usr/bin/env bash
# Exercise the deployed intake block, not a duplicate filter implementation.
# Variables are consumed by eval of the shipped block; one-pass loops test continue.
# shellcheck disable=SC2034,SC2043
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
START="$SCRIPT_DIR/../pr-bot/start.sh"
# Extract the pure helper and actual intake block without starting the daemon.
eval "$(sed -n '/^pr_comment_is_internal() {/,/^}/p' "$START")"
INTAKE=$(sed -n '/^    PAYLOAD_COMMENT_CONTENT=/,/^    fi$/p' "$START")
# This deliberately matches the literal variable reference in the source.
# shellcheck disable=SC2016
[[ "$INTAKE" == *'pr_comment_is_internal "$PAYLOAD_COMMENT_CONTENT"'* ]] || exit 1
PASS=0
check_event() {
  local expected="$1" label="$2" content="$3" dispatched=0 MSG_BODY TIMESTAMP='test'
  MSG_BODY=$(jq -n --arg c "$content" '{resource:{comment:{content:$c}}}')
  # continue must skip the dispatch line in exactly the shipped intake block.
  for _event in once; do
    eval "$INTAKE" >/dev/null
    dispatched=1
  done
  if [ "$dispatched" -ne "$expected" ]; then
    printf 'FAIL: %s (dispatch=%s, expected=%s)\n' "$label" "$dispatched" "$expected"
    return 1
  fi
  PASS=$((PASS + 1))
}
check_event 0 lease '<!-- pr-bot-lease:{"owner":"fixture","iteration":1} -->'
check_event 0 status '<!-- pr-bot-status:PR-123 -->'
check_event 0 recovery '<!-- pr-bot-status:recovery-123-45 -->'
check_event 0 risk-assessed $'Risk assessment\n\n<!-- pr-bot-state:risk-assessed -->'
check_event 0 conflict $'Conflict explanation\n<!-- pr-bot-state:conflict -->'
check_event 0 abandoned '<!-- pr-bot-state:abandoned -->'
check_event 0 future-state '<!-- pr-bot-state:new-state -->'
check_event 0 whitespace $'<!--\tpr-bot-state:risk-assessed -->'
check_event 1 human 'Please fix the failing build and add coverage.'
check_event 1 review 'The response parser mishandles empty results.'
check_event 1 marker-prose 'Please investigate pr-bot-state and pr-bot-lease handling.'
check_event 1 empty ''
check_event 1 other-marker '<!-- human-review:important -->'
check_event 1 incomplete-marker '<!-- pr-bot-state:'
# A non-comment event must still reach the normal downstream routing.
MSG_BODY='{"resource":{"pullRequest":{"pullRequestId":123}}}'
dispatched=0; TIMESTAMP='test'
for _event in once; do eval "$INTAKE" >/dev/null; dispatched=1; done
[ "$dispatched" -eq 1 ];PASS=$((PASS + 1))
printf 'Self-comment filter: %s passed, 0 failed\n' "$PASS"
