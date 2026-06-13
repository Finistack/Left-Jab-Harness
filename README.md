# Left Jab Harness

A client-side [Claude Code](https://claude.com/claude-code) CLI **harness** that autonomously
resolves pull-request review comments, fixes failing builds, rebases merge conflicts, and links
work items on an **Azure DevOps** repository — posting status back to the PR as it goes.

It is a self-contained **bash** daemon: it subscribes to a [ntfy](https://ntfy.sh) push stream of
PR events and drives the ADO REST API. The harness runs from its own checkout and operates on a
**separate target repository** you configure (`TARGET_REPO_DIR`).

## Features

- **Autonomous PR servicing** — addresses review threads, fixes red builds, resolves conflicts,
  links/creates work items, and (optionally) auto-approves & completes low-risk PRs.
- **Opt-out markers** — `[no-auto]` (a human still merges) and `[no-bot]` (full hands-off).
- **Robust under load** — concurrency + memory admission with a four-layer OOM guard, an
  orphan-subprocess reaper, and a self-healing crash/lease/circuit-breaker model.
- **Pluggable Azure DevOps auth** — Personal Access Token, Entra service principal, or
  Workload Identity Federation.
- **Multi-host safe** — a distributed lease (stored as an ADO PR comment) prevents two hosts from
  double-processing the same PR.

## Quick start

```bash
cp src/build/pr-bot/config.env.example src/build/pr-bot/config.env
$EDITOR src/build/pr-bot/config.env        # TARGET_REPO_DIR, ADO_ORG/PROJECT/REPO, NTFY_URL, ADO_AUTH_METHOD
# secrets (ADO_PAT, ANTHROPIC_AUTH_TOKEN, …) → src/build/pr-bot/.secrets.env  (gitignored)

./src/build/pr-bot/install-service.sh
systemctl --user restart pr-bot
journalctl --user -u pr-bot -f
```

See [`src/build/pr-bot/docs/setup-guide.md`](./src/build/pr-bot/docs/setup-guide.md) for the full
configuration reference and [`ARCHITECTURE.md`](./ARCHITECTURE.md) for how it works.

## Requirements

`git`, `curl`, `jq`, and the `claude` CLI. Linux (systemd) is the primary target; macOS
(launchd) is supported with an additional memory-pressure gate.

## Repository layout

| Path | Purpose |
|------|---------|
| `src/build/pr-bot/` | The daemon (`start.sh`) and per-PR orchestrator (`pr_router.sh`) + helpers |
| `src/build/shared/` | Pluggable ADO auth + API + worktree + logging helpers |
| `src/build/test/` | Self-contained unit tests |

## Security

This is a public repository. Secrets live in `.secrets.env`, runtime config in `config.env`, and
bot state in `.pr-bot-state/` — **all gitignored**. Only `config.env.example` (placeholders) is
committed. See [`CLAUDE.md`](./CLAUDE.md) → "Secrets & Configuration".

## License

See [`LICENSE`](./LICENSE).
