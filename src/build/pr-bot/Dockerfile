# Left Jab Harness — runtime image.
#
# A "fat" toolchain image: the harness itself is bash, but it drives the Claude Code
# CLI to service a .NET target repository (build fixes, conflict rebases), so the image
# carries the .NET SDK + Node + git/jq/curl/bash alongside the harness scripts.
#
# IMPORTANT: this image carries NO secrets and NO config. ADO/Anthropic credentials,
# NTFY_URL, ADO_ORG/PROJECT/REPO and TARGET_REPO_DIR are all injected at runtime
# (env / mounted config.env + .secrets.env). The target repository is a runtime volume,
# never baked in. See .dockerignore for the secret/state exclusions.

# .NET SDK 10 (Debian bookworm: ships bash 5 + git; start.sh requires bash 4.3+).
FROM mcr.microsoft.com/dotnet/sdk:10.0

# Node major used to install the Claude Code CLI.
ARG NODE_MAJOR=20
# Pin/override the Claude Code CLI version at build time if desired (default: latest).
ARG CLAUDE_CODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    # Claude Code: keep the daemon's outbound traffic to the essentials.
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# OS packages: curl/jq/git/ca-certificates + Node (for the Claude CLI). The apt upgrade
# patches base-image CVEs. NodeSource provides a current
# Node major (Debian's default is older than the CLI supports).
RUN set -eux; \
    apt-get update && apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        curl jq git ca-certificates gnupg; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update && apt-get install -y --no-install-recommends nodejs; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Fail the build LOUDLY if any required tool is missing or bash is too old (needs 4.3+).
RUN set -eux; \
    for c in bash curl jq git node npm claude dotnet; do command -v "$c" >/dev/null; done; \
    bash -c 'major=${BASH_VERSINFO[0]}; minor=${BASH_VERSINFO[1]}; { [ "$major" -gt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -ge 3 ]; }; }'

# Non-root runtime user (least privilege; owns the app + state tree).
RUN useradd --create-home --shell /bin/bash bot

# Harness scripts only (docs/state/secrets excluded via .dockerignore). The src/build
# layout is preserved so pr-bot/*.sh resolve ../shared/*.sh exactly as on a dev box.
WORKDIR /app
COPY --chown=bot:bot src/build /app/src/build
RUN chmod +x /app/src/build/pr-bot/*.sh /app/src/build/*.sh /app/src/build/git-credential-ado-pat 2>/dev/null || true

USER bot
WORKDIR /app/src/build/pr-bot

# Foreground daemon (no flag = foreground loop; the server-side deployment supplies
# config.env / .secrets.env and the TARGET_REPO_DIR volume). PID 1 is the ntfy loop.
ENTRYPOINT ["/app/src/build/pr-bot/start.sh"]
