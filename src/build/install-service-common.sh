#!/usr/bin/env bash
set -euo pipefail

# install-service-common.sh — Shared OS-service install logic (systemd / launchd).
# Sourced by the bot's install-service.sh after setting BOT_NAME, STATE_DIR, etc.
#
# Required variables (set by caller before sourcing):
#   BOT_NAME      — the service name (e.g. "pr-bot")
#   SCRIPT_DIR    — absolute path to the bot's directory
#   STATE_DIR     — absolute path to the bot's state directory
#   CONFIG_FILE   — absolute path to config.env
#   BUILD_DIR     — absolute path to src/build/
#
# Optional variables (set by caller for bot-specific validation):
#   EXTRA_VALIDATE_FN  — name of a function to call during validation (e.g. validate_repo_root)

# Load shared git credential setup
# shellcheck source=setup-git-credentials.sh
source "$BUILD_DIR/setup-git-credentials.sh"

# --- Pre-flight config validation ---
validate_config() {
  local errors=0

  echo "🔍 Validating configuration..."

  # 1. config.env exists
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "   ❌ config.env not found at $CONFIG_FILE"
    echo "      Run: cp config.env.example config.env && \$EDITOR config.env"
    return 1
  fi
  echo "   ✅ config.env found"

  # Validate config.env contains only safe assignments. The value portion forbids
  # the shell metacharacters ; & | < > (and \) so a line like `FOO=x && rm -rf /`,
  # `FOO=x | sh`, or `FOO=x > /etc/hosts` can't smuggle a command past the `source`
  # below — left-anchoring alone (^VAR=) would let those through.
  if grep -qvE '^\s*#|^\s*$|^(export\s+)?[A-Za-z_][A-Za-z0-9_]*=[^\;&|<>]*$' "$CONFIG_FILE"; then
    echo "   ❌ config.env contains unsafe lines (non-assignment or shell metacharacters)"
    echo "      Only VAR=value lines (no ; & | < >), comments (#), and blank lines are allowed."
    return 1
  fi

  # Reject command-substitution patterns — $(...) and backticks — in values.
  # These execute arbitrary commands when the file is source'd.
  if grep -vE '^\s*#|^\s*$' "$CONFIG_FILE" | grep -qE '\$\(|`'; then
    echo "   ❌ config.env contains command substitution (\$() or backticks) — security risk"
    echo "      Use plain literal values only; no shell expansion."
    return 1
  fi

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  # Auto-load sibling .secrets.env (gitignored) if present, so secrets like
  # ADO_PAT / ANTHROPIC_* don't have to be pre-exported before running install.
  local secrets_file="${SECRETS_FILE:-$(dirname "$CONFIG_FILE")/.secrets.env}"
  if [ -f "$secrets_file" ]; then
    if grep -qvE '^\s*#|^\s*$|^(export\s+)?[A-Za-z_][A-Za-z0-9_]*=[^\;&|<>]*$' "$secrets_file"; then
      echo "   ❌ .secrets.env contains unsafe lines (non-assignment or shell metacharacters)"
      return 1
    fi
    if grep -vE '^\s*#|^\s*$' "$secrets_file" | grep -qE '\$\(|`'; then
      echo "   ❌ .secrets.env contains command substitution (\$() or backticks) — security risk"
      return 1
    fi
    set -a
    # shellcheck source=/dev/null
    source "$secrets_file"
    set +a
    echo "   ✅ .secrets.env loaded"
  fi

  # 2. Required variables (common to both bots)
  if [ -z "${NTFY_URL:-}" ]; then
    echo "   ❌ NTFY_URL is not set"; errors=$((errors + 1))
  else
    echo "   ✅ NTFY_URL = ${NTFY_URL}"
  fi

  if [ -z "${ADO_ORG:-}" ]; then
    echo "   ❌ ADO_ORG is not set"; errors=$((errors + 1))
  else
    echo "   ✅ ADO_ORG = ${ADO_ORG}"
  fi

  if [ -z "${ADO_PROJECT:-}" ]; then
    echo "   ❌ ADO_PROJECT is not set"; errors=$((errors + 1))
  else
    echo "   ✅ ADO_PROJECT = ${ADO_PROJECT}"
  fi

  if [ -z "${ADO_PAT:-}" ]; then
    echo "   ❌ ADO_PAT is not set (generate at https://dev.azure.com/${ADO_ORG:-org}/_usersSettings/tokens)"
    errors=$((errors + 1))
  else
    echo "   ✅ ADO_PAT is set (${#ADO_PAT} chars)"
  fi

  # 3. Bot-specific validation hook
  if [ -n "${EXTRA_VALIDATE_FN:-}" ] && declare -f "$EXTRA_VALIDATE_FN" >/dev/null 2>&1; then
    if ! "$EXTRA_VALIDATE_FN"; then
      errors=$((errors + 1))
    fi
  fi

  # 4. Prerequisites
  for cmd in curl jq git claude bash; do
    if command -v "$cmd" >/dev/null 2>&1; then
      local ver=""
      case "$cmd" in
        bash)   ver="$(bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)" ;;
        claude) ver="$(claude --version 2>/dev/null || echo 'unknown')" ;;
        git)    ver="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" ;;
        jq)     ver="$(jq --version 2>/dev/null || echo 'unknown')" ;;
        curl)   ver="$(curl --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" ;;
      esac
      echo "   ✅ $cmd found ($ver)"
    else
      echo "   ❌ $cmd not found"; errors=$((errors + 1))
    fi
  done

  # Bash version >= 4
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "   ❌ bash 4+ required (found ${BASH_VERSION}). On macOS: brew install bash"
    errors=$((errors + 1))
  fi

  # 5. Git repo + credential setup — wire credentials on the repo the bot PUSHES to.
  # With TARGET_REPO_DIR decoupling, the harness checkout is NOT the serviced repo:
  # it may be a public GitHub clone (whose remote setup_git_credentials rejects) or a
  # git worktree (whose .git is a *file*, not a dir). Credentials belong on the target.
  # Fall back to the harness toplevel for the legacy "harness lives inside the serviced
  # repo" layout (TARGET_REPO_DIR unset) — preserving prior behavior exactly.
  local cred_repo_hint="${TARGET_REPO_DIR:-$SCRIPT_DIR}"
  local repo_root
  repo_root=$(git -C "$cred_repo_hint" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$repo_root" ] && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "   ✅ Git repository detected at $repo_root"
    if ! setup_git_credentials "$repo_root"; then
      errors=$((errors + 1))
    fi
  else
    echo "   ❌ Not inside a git repository (checked: $cred_repo_hint)"; errors=$((errors + 1))
  fi

  # 6. Connectivity checks
  if [ -n "${NTFY_URL:-}" ]; then
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NTFY_URL}/health" 2>/dev/null) || http_code="000"
    if [ "$http_code" = "200" ]; then
      echo "   ✅ ntfy server reachable"
    else
      echo "   ⚠️  ntfy server returned HTTP $http_code (may be behind auth or different health endpoint)"
    fi
  fi

  if [ -n "${ADO_PAT:-}" ] && [ -n "${ADO_ORG:-}" ]; then
    local ado_code
    ado_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Authorization: Basic $(echo -n ":${ADO_PAT}" | base64 | tr -d '\n')" \
      "https://dev.azure.com/${ADO_ORG}/_apis/projects?api-version=7.1" 2>/dev/null) || ado_code="000"
    if [[ "$ado_code" =~ ^2[0-9][0-9]$ ]]; then
      echo "   ✅ ADO API reachable (PAT valid)"
    elif [[ "$ado_code" =~ ^(401|403)$ ]]; then
      echo "   ❌ ADO API auth failed (HTTP $ado_code) — check ADO_PAT"
      errors=$((errors + 1))
    else
      echo "   ⚠️  ADO API returned HTTP $ado_code (network issue?)"
    fi
  fi

  # 7. start.sh is executable
  if [ -x "$SCRIPT_DIR/start.sh" ]; then
    echo "   ✅ start.sh is executable"
  else
    echo "   ⚠️  start.sh is not executable — fixing..."
    chmod +x "$SCRIPT_DIR/start.sh"
    echo "   ✅ start.sh is now executable"
  fi

  if [ "$errors" -gt 0 ]; then
    echo ""
    echo "❌ Validation failed with $errors error(s). Fix the issues above before installing."
    return 1
  fi

  echo ""
  echo "✅ All checks passed"
  return 0
}

# --- Service install/uninstall ---
install_service() {
  local action="${1:-install}"

  # Run validation for install (skip for uninstall)
  if [ "$action" != "uninstall" ]; then
    if ! validate_config; then
      exit 1
    fi
    echo ""
  fi

  case "$(uname -s)" in
    Linux)
      local unit_file="$SCRIPT_DIR/${BOT_NAME}.service"
      local user_unit_dir="${HOME}/.config/systemd/user"
      local dest="${user_unit_dir}/${BOT_NAME}.service"

      if [ "$action" = "uninstall" ]; then
        echo "🛑 Uninstalling ${BOT_NAME} systemd user service..."
        systemctl --user stop "$BOT_NAME" 2>/dev/null || true
        systemctl --user disable "$BOT_NAME" 2>/dev/null || true
        rm -f "$dest"
        systemctl --user daemon-reload
        echo "✅ Service uninstalled"
        exit 0
      fi

      echo "🐧 Installing ${BOT_NAME} as systemd user service..."
      mkdir -p "$user_unit_dir"

      # Patch all %h-based paths in the unit file to actual absolute paths.
      # Uses a generic pattern that works for any bot directory name.
      sed -e "s|%h[^ ]*/start.sh|${SCRIPT_DIR}/start.sh|g" \
          -e "s|%h[^ ]*/config.env|${SCRIPT_DIR}/config.env|g" \
          -e "s|WorkingDirectory=%h[^ ]*|WorkingDirectory=${SCRIPT_DIR}|g" \
          "$unit_file" > "$dest"

      systemctl --user daemon-reload
      systemctl --user enable "$BOT_NAME"
      systemctl --user start "$BOT_NAME"

      if loginctl enable-linger "$USER" 2>/dev/null; then
        echo "✅ Linger enabled — service will survive logout and start at boot"
      else
        echo "⚠️  loginctl enable-linger failed (may need admin/polkit)"
        echo "   Service will run while logged in. Use --daemon mode as fallback for SSH sessions."
      fi

      echo "✅ Service installed and started"
      echo "   Status:  systemctl --user status ${BOT_NAME}"
      echo "   Logs:    journalctl --user -u ${BOT_NAME} -f"
      echo "   Stop:    systemctl --user stop ${BOT_NAME}"
      echo "   Remove:  $0 uninstall"
      ;;

    Darwin)
      local plist_src="$SCRIPT_DIR/com.finistack.${BOT_NAME}.plist"
      local plist_dir="${HOME}/Library/LaunchAgents"
      local plist_dest="${plist_dir}/com.finistack.${BOT_NAME}.plist"

      if [ "$action" = "uninstall" ]; then
        echo "🛑 Uninstalling ${BOT_NAME} launchd agent..."
        launchctl bootout "gui/$(id -u)/com.finistack.${BOT_NAME}" 2>/dev/null || \
          launchctl unload "$plist_dest" 2>/dev/null || true
        rm -f "$plist_dest"
        echo "✅ Service uninstalled"
        exit 0
      fi

      echo "🍎 Installing ${BOT_NAME} as launchd user agent..."
      mkdir -p "$plist_dir"

      # launchd runs with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin) and no shell
      # profile. That resolves `#!/usr/bin/env bash` to /bin/bash 3.2 (start.sh needs
      # 4.3+) and hides Homebrew-installed claude/node/git. Build a PATH from where
      # the real tools live so the agent matches an interactive shell.
      local svc_path="/usr/bin:/bin:/usr/sbin:/sbin"
      local tool_dir tool_path
      for tool in bash claude node git jq curl; do
        tool_path="$(command -v "$tool" 2>/dev/null)" || continue
        tool_dir="$(dirname "$tool_path")"
        if [ -d "$tool_dir" ] && [[ ":$svc_path:" != *":$tool_dir:"* ]]; then
          svc_path="${tool_dir}:${svc_path}"
        fi
      done

      sed -e "s|__SCRIPT_PATH__|${SCRIPT_DIR}/start.sh|g" \
          -e "s|__STATE_DIR__|${STATE_DIR}|g" \
          -e "s|__PATH__|${svc_path}|g" \
          -e "s|__WORKING_DIR__|${SCRIPT_DIR}|g" \
          "$plist_src" > "$plist_dest"

      # Back-compat: if an older template lacked the PATH/WorkingDirectory keys,
      # the placeholders won't exist — inject them so the agent still works.
      if ! grep -q "<key>WorkingDirectory</key>" "$plist_dest"; then
        if ! /usr/libexec/PlistBuddy -c "Add :WorkingDirectory string ${SCRIPT_DIR}" "$plist_dest" 2>/dev/null; then
          echo "   ⚠️  Failed to inject WorkingDirectory into plist — service may start in /"
        fi
      fi
      if ! grep -q "<key>EnvironmentVariables</key>" "$plist_dest"; then
        if ! /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$plist_dest" 2>/dev/null; then
          echo "   ⚠️  Failed to inject EnvironmentVariables dict — service will use bare macOS PATH"
        elif ! /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:PATH string ${svc_path}" "$plist_dest" 2>/dev/null; then
          echo "   ⚠️  Failed to inject PATH into EnvironmentVariables — service will use bare macOS PATH"
        fi
      fi

      # Reload idempotently: bootout any prior instance, then bootstrap fresh.
      launchctl bootout "gui/$(id -u)/com.finistack.${BOT_NAME}" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist_dest" 2>/dev/null || \
        launchctl load "$plist_dest" 2>/dev/null || true

      echo "✅ Service installed and started"
      echo "   PATH:    ${svc_path}"
      echo "   WorkDir: ${SCRIPT_DIR}"
      echo "   Status:  launchctl list | grep ${BOT_NAME}"
      echo "   Logs:    tail -f ${STATE_DIR}/daemon.log"
      echo "   Stop:    launchctl bootout gui/$(id -u)/com.finistack.${BOT_NAME}"
      echo "   Remove:  $0 uninstall"
      ;;

    *)
      echo "❌ Unsupported OS: $(uname -s)"
      echo "   Use --daemon mode instead: ./start.sh --daemon"
      exit 1
      ;;
  esac
}
