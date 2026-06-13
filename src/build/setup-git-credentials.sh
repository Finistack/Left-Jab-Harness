#!/usr/bin/env bash
# setup-git-credentials.sh — Configure git to use ADO_PAT for push/fetch.
#
# Sourced by the harness install script. Can also be run standalone.
# Converts SSH remotes to HTTPS and wires up the credential helper.
#
# Usage: source setup-git-credentials.sh && setup_git_credentials /path/to/repo
#   or:  ./setup-git-credentials.sh /path/to/repo
#
# Requires: ADO_PAT in environment (usually from config.env)

setup_git_credentials() {
  local repo_root="$1"
  local build_dir
  build_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local cred_helper="$build_dir/git-credential-ado-pat"
  local errors=0

  if [ ! -x "$cred_helper" ]; then
    echo "   ❌ Credential helper not found: $cred_helper"
    return 1
  fi

  # 1. Check current remote URL
  local remote_url
  remote_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
  if [ -z "$remote_url" ]; then
    echo "   ❌ No 'origin' remote found in $repo_root"
    return 1
  fi
  echo "   📡 Current remote: $remote_url"

  # 2. If SSH, convert to HTTPS
  # SSH formats:
  #   git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
  #   {org}@vs-ssh.visualstudio.com:v3/{org}/{project}/{repo}
  if echo "$remote_url" | grep -qE '(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)'; then
    # Extract org/project/repo from SSH URL
    local ado_org ado_project ado_repo
    if echo "$remote_url" | grep -q 'ssh.dev.azure.com:v3/'; then
      # git@ssh.dev.azure.com:v3/org/project/repo
      ado_org=$(echo "$remote_url" | sed 's|.*:v3/||' | cut -d/ -f1)
      ado_project=$(echo "$remote_url" | sed 's|.*:v3/||' | cut -d/ -f2)
      ado_repo=$(echo "$remote_url" | sed 's|.*:v3/||' | cut -d/ -f3)
    elif echo "$remote_url" | grep -q 'vs-ssh.visualstudio.com:v3/'; then
      ado_org=$(echo "$remote_url" | sed 's|.*:v3/||' | cut -d/ -f1)
      ado_project=$(echo "$remote_url" | sed 's|.*:v3/||' | cut -d/ -f2)
      ado_repo=$(echo "$remote_url" | sed 's|.*:v3/||' | cut -d/ -f3)
    fi

    if [ -n "$ado_org" ] && [ -n "$ado_project" ] && [ -n "$ado_repo" ]; then
      local https_url="https://dev.azure.com/${ado_org}/${ado_project}/_git/${ado_repo}"
      echo "   🔄 Converting SSH → HTTPS remote"
      echo "      From: $remote_url"
      echo "      To:   $https_url"

      # Store original as 'origin-ssh' for easy revert
      if ! git -C "$repo_root" remote get-url origin-ssh >/dev/null 2>&1; then
        git -C "$repo_root" remote add origin-ssh "$remote_url" 2>/dev/null || true
        echo "   💾 Original SSH URL saved as 'origin-ssh' remote"
      fi

      git -C "$repo_root" remote set-url origin "$https_url"
      echo "   ✅ Remote 'origin' updated to HTTPS"
    else
      echo "   ⚠️  Could not parse SSH URL — manual conversion needed"
      echo "      Expected: git@ssh.dev.azure.com:v3/{org}/{project}/{repo}"
      errors=$((errors + 1))
    fi
  elif echo "$remote_url" | grep -qE 'https?://([^/@]+@)?dev\.azure\.com'; then
    # Tolerate optional userinfo (e.g. https://org@dev.azure.com/...), which
    # ADO emits by default. The credential helper supplies the PAT regardless.
    echo "   ✅ Remote is already HTTPS"
  else
    echo "   ⚠️  Unrecognized remote URL format: $remote_url"
    echo "      Bot credentials only work with dev.azure.com HTTPS URLs"
    errors=$((errors + 1))
  fi

  # 3. Configure the credential helper (repo-local config only)
  # The helper reads ADO_PAT from the environment at runtime.
  # We need TWO things:
  #   a) An empty credential.helper entry to reset the chain and block global GCM
  #   b) Our custom helper as the active entry after the reset
  # This ensures GCM (installed globally) doesn't intercept before our PAT helper.
  # Note: the empty "" entry only blocks global helpers — it does not affect
  # other local credential helpers since we only touch our own entries.
  local current_helper
  current_helper=$(git -C "$repo_root" config --local --get-all credential.helper 2>/dev/null | tail -1 || true)
  if [ "$current_helper" = "$cred_helper" ]; then
    echo "   ✅ Credential helper already configured"
  else
    # Reset only credential.helper entries (preserves any host-scoped helpers for other hosts)
    git -C "$repo_root" config --local --unset-all credential.helper 2>/dev/null || true
    # Empty entry resets the helper chain, blocking global GCM from intercepting
    git -C "$repo_root" config --local credential.helper ""
    git -C "$repo_root" config --local --add credential.helper "$cred_helper"
    echo "   ✅ Credential helper configured (GCM blocked, repo-local only)"
  fi

  # 4. Also set credential.useHttpPath=true for ADO (required — ADO uses path-based auth)
  git -C "$repo_root" config --local credential.useHttpPath true 2>/dev/null || true

  # 5. Verify it works
  if [ -n "${ADO_PAT:-}" ]; then
    echo "   🔍 Testing git remote access..."
    # Use inline env var to pass ADO_PAT to the credential helper subprocess without
    # permanently exporting it into the caller's environment (since this file is sourced).
    if GIT_TERMINAL_PROMPT=0 ADO_PAT="$ADO_PAT" git -C "$repo_root" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
      echo "   ✅ git ls-remote succeeded — push/fetch will work"
    else
      echo "   ❌ git ls-remote failed — credential helper or PAT may be broken"
      errors=$((errors + 1))
    fi
  else
    echo "   ⚠️  ADO_PAT not in environment — skipping remote verification"
    echo "      (Will be available at runtime via EnvironmentFile)"
  fi

  return $errors
}

# Allow standalone execution
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  if [ -z "$REPO_ROOT" ]; then
    echo "Usage: $0 [/path/to/repo]"
    echo "  Requires ADO_PAT environment variable"
    exit 1
  fi
  setup_git_credentials "$REPO_ROOT"
fi
