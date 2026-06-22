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

# strip_hostile_insteadof <repo> — Remove repo-LOCAL url.<base>.insteadOf /
# pushInsteadOf rules that force an ADO *HTTPS* URL onto an ADO *SSH* transport.
#
# Such a rule (e.g. url."git@ssh.dev.azure.com:v3/org/proj/".insteadOf =
# "https://dev.azure.com/org/proj/_git/") makes git silently rewrite the HTTPS
# origin onto SSH on *every* operation. Under the systemd --user service there is
# no SSH agent, so every git op then fails with a misleading "PAT may be broken",
# wedging the bot. (Note: the inline `-c url.<base>.insteadOf=` trick does NOT
# neutralize it — insteadOf is a multivar and `-c` only appends — so the rule
# must be physically removed.)
#
# HOSTILE iff BOTH:
#   * the section <base> is an ADO SSH host (ssh.dev.azure.com / vs-ssh.visualstudio.com), AND
#   * at least one of its values is an ADO HTTPS URL (dev.azure.com / *.visualstudio.com).
# github rules, https->https rules, non-ADO rules, and the origin-ssh backup
# remote are all left untouched. Local-only, idempotent, never fatal.
strip_hostile_insteadof() {
  local repo_root="$1"
  [ -n "$repo_root" ] || return 0

  # An ADO SSH host appearing as the section base means the rule rewrites ONTO SSH.
  local ssh_host_re='(^|@|/)(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)([:/]|$)'
  # An ADO HTTPS URL as a value means it is ADO-HTTPS being forced onto that SSH base.
  local ado_https_re='^https?://([^/@]+@)?(dev\.azure\.com|[^/]*\.visualstudio\.com)'

  local key base val
  local -a hostile_bases=()
  # --name-only --get-regexp case-folds the key, so the suffix arrives lowercased
  # (.insteadof / .pushinsteadof). Process substitution (not a pipe) so the array
  # we build survives into this shell.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    base="${key#url.}"
    base="${base%.insteadof}"
    base="${base%.pushinsteadof}"
    [[ "$base" =~ $ssh_host_re ]] || continue
    while IFS= read -r val; do
      [ -n "$val" ] || continue
      if [[ "$val" =~ $ado_https_re ]]; then
        hostile_bases+=("$base")
        break
      fi
    done < <(git -C "$repo_root" config --local --get-all "$key" 2>/dev/null)
  done < <(git -C "$repo_root" config --local --name-only --get-regexp 'url\..*\.(insteadof|pushinsteadof)' 2>/dev/null || true)

  # Remove each hostile section exactly once (a base may surface via both
  # insteadOf and pushInsteadOf, and a multivar surfaces its key repeatedly).
  local b seen=" "
  for b in ${hostile_bases[@]+"${hostile_bases[@]}"}; do
    case "$seen" in *" $b "*) continue ;; esac
    seen="$seen$b "
    git -C "$repo_root" config --local --remove-section "url.$b" 2>/dev/null || true
    echo "   🧹 Stripped hostile insteadOf (forces ADO-HTTPS→SSH): url.$b"
  done
  return 0
}

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

  # 0. Strip any hostile ADO-HTTPS→SSH insteadOf/pushInsteadOf rewrite rules FIRST,
  # before the remote is read or probed below. A stray such rule silently rewrites
  # the HTTPS origin onto SSH (no agent under systemd --user → every git op fails),
  # and the old self-heal looped forever because `git remote get-url origin`
  # resolves *through* insteadOf and always reported SSH. Both consumers (installer
  # + router self-heal) inherit this from a single placement.
  strip_hostile_insteadof "$repo_root"

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

  # 5. Verify it works — rewrite-proof + self-diagnosing.
  # Step 0 already stripped hostile LOCAL insteadOf rules. So if origin's RAW local
  # URL is HTTPS yet the RESOLVED url is still SSH, the culprit is a surviving
  # GLOBAL/SYSTEM insteadOf rule — name it, don't blame the PAT.
  local raw_url resolved_url
  raw_url=$(git -C "$repo_root" config --local remote.origin.url 2>/dev/null || true)
  resolved_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)

  if echo "$raw_url" | grep -qE '^https?://([^/@]+@)?(dev\.azure\.com|[^/@]*\.visualstudio\.com)' \
     && echo "$resolved_url" | grep -qE '(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)'; then
    echo "   ❌ origin is HTTPS ($raw_url) but resolves to SSH ($resolved_url) AFTER the"
    echo "      local insteadOf strip — a surviving GLOBAL or SYSTEM insteadOf rule is"
    echo "      forcing ADO-HTTPS→SSH (there is no SSH agent under systemd --user). Find & remove it:"
    echo "        git config --global --get-regexp 'url\\..*\\.insteadof'"
    echo "        git config --system --get-regexp 'url\\..*\\.insteadof'"
    errors=$((errors + 1))
  fi

  if [ -n "${ADO_PAT:-}" ]; then
    echo "   🔍 Testing git remote access..."
    # Probe the RAW HTTPS literal (not the 'origin' alias) with global/system git
    # config neutralized, so NO surviving insteadOf rule can rewrite it back onto
    # SSH and yield a misleading failure. Inline ADO_PAT for the credential helper
    # subprocess without exporting it into the (sourced) caller's environment; the
    # repo-LOCAL credential.helper + useHttpPath set above still apply.
    local probe_url="${raw_url:-$resolved_url}"
    if GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        ADO_PAT="$ADO_PAT" git -C "$repo_root" ls-remote --exit-code "$probe_url" HEAD >/dev/null 2>&1; then
      echo "   ✅ git ls-remote (HTTPS) succeeded — push/fetch will work"
    else
      echo "   ❌ git ls-remote failed against the HTTPS literal — PAT/credential helper or network"
      echo "      probed: $probe_url"
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
