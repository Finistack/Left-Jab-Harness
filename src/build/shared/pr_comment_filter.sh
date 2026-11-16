#!/usr/bin/env bash

# Internal comments are notifications of the bot's own work, not new work.
# Match the machine comment syntax, not ordinary prose mentioning a marker name.
pr_comment_is_internal() {
  printf '%s\n' "${1:-}" | grep -Eq '<!--[[:space:]]*pr-bot-(lease|status|state):[^>]*-->'
}
