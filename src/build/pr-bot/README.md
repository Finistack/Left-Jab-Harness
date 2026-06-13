# PR Bot — Automated PR Comment Handler

Subscribes to ADO PR comment webhooks via ntfy and drives Claude Code to address review comments automatically.

## Architecture

```
ADO PR Comment → Service Hook → ntfy → start.sh → pr_router.sh → Claude Code → git push → ado_resolve.sh
                                          ↕                ↕
                                   pr_heartbeat.sh   pr_policies.sh (risk classify → auto-approve → auto-complete)
```

## Quick Start

```bash
# 1. Configure
cp config.env.example config.env
# Create .secrets.env with ADO_PAT, ANTHROPIC_* vars (see docs/setup-guide.md)

# 2. Start
./start.sh                # foreground
./start.sh --daemon       # background (survives SSH disconnect)
./start.sh --service      # systemd mode

# 3. (Optional) Test
./start.sh --test
```

## Documentation

See **[docs/setup-guide.md](docs/setup-guide.md)** for:
- Complete environment variables reference
- Authentication methods (PAT, Entra ID Service Principal, Workload Identity)
- ADO Service Hook configuration
- systemd installation
- Token-Savior MCP setup
- Troubleshooting guide

## Prerequisites

- `curl`, `jq`, `git`, `bash 4.3+`
- `claude` — [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- ADO credentials (PAT or Entra ID — see setup guide)

## Key Features

- **Memory-aware concurrency** — leaky-bucket admission control based on PR size classification (`MAX_CONCURRENT=2`, `MEMORY_BUDGET_MB=2700` under a 3G cgroup cap)
- **RSS watchdog** — kills runaway Claude processes exceeding 150% of estimated memory, measured over the **full process subtree** (router→timeout→claude→MCP), not just depth-1
- **Aggregate OOM guard** — sheds the youngest session when the cgroup's own `memory.current` nears the wall, before `KillMode=control-group` kills the whole bot
- **Crash recovery** — persists messages to disk queue, replays on restart
- **OOM self-heal** — reclaims dead-PID locks and orphaned same-host leases so PRs don't "appear to wait" for the lease TTL after a SIGKILL
- **Heartbeat orphan recovery** — polls ADO for PRs with unresolved work but no active lease
- **Multi-auth support** — PAT, Entra ID Service Principal, Workload Identity Federation
- **Risk classification** — Claude-powered risk assessment with auto-approve/complete for LOW/MEDIUM
- **Token-Savior MCP** — optional token reduction via indexed codebase search

## Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help |
| `-c, --config FILE` | Config file path (default: `./config.env`) |
| `-t, --topic TOPIC` | ntfy topic (default: `pr-bot`) |
| `-n, --dry-run` | Print messages without invoking Claude |
| `-v, --verbose` | Verbose logging |
| `--service` | systemd foreground mode |
| `--daemon` | Background mode |
| `--stop` | Stop daemon |
| `--status` | Check daemon status |
| `--test` | Publish test message and exit |

## State

- `.pr-bot-state/` — per-PR state, locks, worktrees, queue, deferred messages
- `.secrets.env` — secrets (gitignored)
- `config.env` — runtime config (non-secret)

## Troubleshooting

| Issue | Fix |
|-------|-----|
| "Missing required command: claude" | `npm install -g @anthropic-ai/claude-code` |
| No messages received | Check service hook + ntfy health |
| OOM kills (whole bot restarts) | Lower `MAX_CONCURRENT`/`MEMORY_BUDGET_MB`, or raise `MemoryMax` in the unit (keep budget ~300–400 MB under it). Check `journalctl … \| grep -iE 'oom\|memory guard'` |
| PR "appears to wait" ~30 min after a restart | Orphaned lease/lock from a SIGKILL — auto-reclaimed on next event; manual: `rm -rf .pr-bot-state/pr-<ID>.lock` |
| HIGH risk auto-approved | Upgrade — fixed case-sensitivity bug in risk normalization |
| Duplicate processing | Check `.pr-bot-state/queue/` and `.pr-bot-state/deferred/` |
