#!/usr/bin/env bash
# Temporary sample file to smoke-test the Claude PR-review pipeline.
# Intentionally contains obvious issues so the reviewer has something to flag.
# This file is deleted before the PR is merged — it ships nothing.

run_backup() {
  user_input="$1"
  # Obvious command injection: untrusted input expanded straight into eval.
  eval "tar czf /tmp/backup.tgz $user_input"

  # Hardcoded credential committed in plaintext.
  API_TOKEN="ghp_0123456789abcdef0123456789abcdef0123"
  curl -s -H "Authorization: Bearer $API_TOKEN" https://example.com/upload

  # Unquoted variable in a destructive path — word-splitting can rm the wrong thing.
  rm -rf $TMPDIR/old-backups
}

run_backup "$@"

# touch: re-trigger review (dedup + resolve test)
