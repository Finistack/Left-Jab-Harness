# PR Bot Setup Guide

Complete guide for setting up and operating the Left Jab Bot (PR Bot) — an automated PR comment handler powered by Claude Code.

## Prerequisites

- **curl**, **jq**, **git** — standard CLI tools
- **claude** — [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- **python3** — for token-savior MCP (optional)
- **bash 4.3+** — required for `wait -n` and associative arrays

## Quick Start (PAT Auth)

```bash
# 1. Copy config template
cp config.env.example config.env

# 2. Create secrets file (gitignored)
cat > .secrets.env <<'EOF'
ADO_PAT="your-personal-access-token"
ANTHROPIC_BASE_URL="https://api.anthropic.com/"
ANTHROPIC_AUTH_TOKEN="your-anthropic-key"
ANTHROPIC_MODEL="claude-sonnet-4-20250514"
ANTHROPIC_SMALL_FAST_MODEL="claude-haiku-3"
EOF

# 3. Start
./start.sh              # foreground
./start.sh --daemon     # background (survives SSH disconnect)
./start.sh --service    # systemd mode (foreground, journal logging)
```

## Environment Variables Reference

### Azure DevOps

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ADO_ORG` | Yes | `your-org` | Azure DevOps organization name |
| `ADO_PROJECT` | Yes | `your-project` | Azure DevOps project name |
| `ADO_REPO` | No | `your-repo` | Repository name |
| `ADO_AUTH_METHOD` | No | `pat` | Auth method: `pat`, `entra-sp`, `entra-wi` |
| `ADO_PAT` | When `pat` | — | Personal Access Token |
| `AZURE_TENANT_ID` | When `entra-*` | — | Entra ID tenant GUID |
| `AZURE_CLIENT_ID` | When `entra-*` | — | App registration client ID |
| `AZURE_CLIENT_SECRET` | When `entra-sp` | — | Client secret |
| `AZURE_FEDERATED_TOKEN_FILE` | When `entra-wi` | — | Path to projected token file |

### ntfy

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NTFY_URL` | Yes | `https://ntfy.example.com/ntfy` | ntfy server URL |
| `NTFY_TOPIC` | No | `pr-bot` | ntfy topic name |

### Claude Code CLI

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ANTHROPIC_BASE_URL` | Yes | — | LLM API endpoint |
| `ANTHROPIC_AUTH_TOKEN` | Yes | — | Authentication token |
| `ANTHROPIC_MODEL` | Yes | — | Primary model identifier |
| `ANTHROPIC_SMALL_FAST_MODEL` | No | — | Fast model for risk classification |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | No | `65536` | Max output tokens per session |
| `CLAUDE_TIMEOUT` | No | `1800` | Per-session timeout in seconds |
| `CLAUDE_MAX_TURNS` | No | `50` | Max turns per Claude session |
| `CLAUDE_MAX_RETRIES` | No | `2` | Retries on max_turns hit |

### Resource Limits

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MEMORY_BUDGET_MB` | No | `2048` | Total memory budget for all sessions |
| `MAX_CONCURRENT` | No | `3` | Hard cap on parallel PR handlers |
| `HEARTBEAT_INTERVAL_SECS` | No | `300` | Orphan PR check interval |

### MCP / Token-Savior

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ENABLE_TOKEN_SAVIOR` | No | `true` | Enable token-savior-recall MCP |
| `TOKEN_SAVIOR_VENV` | No | `~/.local/share/token-savior-venv` | Venv path for token-savior |

## Authentication Methods

### PAT (Personal Access Token) — Default

Simplest setup. Create a PAT at `https://dev.azure.com/{org}/_usersSettings/tokens`.

**Required scopes:**
- Code: Read & Write
- Pull Request Threads: Read & Write
- Work Items: Read, Write, & Manage
- Build: Read

Set in `.secrets.env`:
```bash
ADO_AUTH_METHOD="pat"
ADO_PAT="your-pat-here"
```

### Entra ID Service Principal (Client Secret)

For production/CI environments where PATs are not suitable.

**Setup steps:**
1. **Create App Registration**: Azure Portal → Entra ID → App registrations → New registration
2. **Add client secret**: Certificates & secrets → New client secret → copy the value
3. **Add SP to ADO**: Organization Settings → Users → Add → enter the app's client ID
4. **Grant permissions**: Project Settings → Permissions → add the SP with Contribute + PR management

Set in `.secrets.env`:
```bash
ADO_AUTH_METHOD="entra-sp"
AZURE_TENANT_ID="your-tenant-guid"
AZURE_CLIENT_ID="your-app-client-id"
AZURE_CLIENT_SECRET="your-client-secret"
```

### Entra ID Workload Identity Federation (Kubernetes)

For running the bot in AKS with no secrets required.

**Setup steps:**
1. Same App Registration as above
2. Certificates & secrets → Federated credentials → Add credential
   - Scenario: Kubernetes
   - Cluster issuer URL: your AKS OIDC issuer
   - Namespace + Service Account: match your deployment
3. Deploy with service account annotation

Set in config:
```bash
ADO_AUTH_METHOD="entra-wi"
AZURE_TENANT_ID="your-tenant-guid"
AZURE_CLIENT_ID="your-app-client-id"
AZURE_FEDERATED_TOKEN_FILE="/var/run/secrets/azure/tokens/azure-identity-token"
```

## ADO Service Hook Setup

1. **Project Settings → Service hooks → Create subscription**
2. Service: **Web Hooks**
3. Event: **Pull request commented on**
4. Filter: Repository = your repo (or all)
5. URL: `https://your-ntfy-server/topic-name`
6. Content-Type: `application/json`

## systemd Installation

```bash
# Install (or reinstall) the systemd user service
./install-service.sh

# Manage
systemctl --user start pr-bot
systemctl --user status pr-bot
systemctl --user restart pr-bot
journalctl --user -u pr-bot -f

# After changing the unit file
systemctl --user daemon-reload
systemctl --user restart pr-bot
```

The default `MemoryMax` is 3G. Adjust in `~/.config/systemd/user/pr-bot.service` if needed.

## Token-Savior MCP (Optional)

Token-savior-recall reduces token usage by providing indexed codebase search.

```bash
# Auto-installed on first run if ENABLE_TOKEN_SAVIOR=true (default)
# Manual install:
python3 -m venv ~/.local/share/token-savior-venv
~/.local/share/token-savior-venv/bin/pip install token-savior-recall
```

Token/tool usage is logged after each Claude session — look for `📊 Token usage:` and `🔧 Tool usage:` in the logs.

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| OOM kills (exit code 137) | Claude sessions exceeding memory | Reduce `MAX_CONCURRENT`, lower `MEMORY_BUDGET_MB` |
| HIGH risk PRs auto-approved | Case-sensitive risk comparison | Fixed in v2 — risk level normalized to lowercase |
| PAT expired (401/403) | ADO PAT rotation needed | Regenerate at `dev.azure.com/{org}/_usersSettings/tokens` |
| Entra token errors | Incorrect SP setup or expired secret | Check `AZURE_*` vars, verify SP has ADO access |
| ntfy disconnects | Network issues, ntfy restart | Bot auto-reconnects with exponential backoff |
| PR processed 60+ times | OOM restart flood replaying ntfy cache | Fixed: dedup via seen-ids + persistent queue |
| "Missing required command: claude" | CLI not installed | `npm install -g @anthropic-ai/claude-code` |
| Token-savior install fails | No python3 or pip issues | Set `ENABLE_TOKEN_SAVIOR=false` to disable |
