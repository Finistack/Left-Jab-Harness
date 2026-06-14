# Left Jab Harness — Claude Code Project Guide

> **This is the thin always-on core.** Detailed, task-specific guidance lives in
> [`.claude/rules/`](./.claude/rules/) — auto-discovered by Claude Code. Files with
> `paths:` frontmatter load **only when you touch matching files**.

## Project Overview

**Left Jab** is a client-side [Claude Code](https://claude.com/claude-code) CLI **harness**: a
bash daemon that watches an Azure DevOps repository for pull-request events and autonomously
addresses review comments, fixes failing builds, resolves merge conflicts, and links work items —
posting status back to the PR as it goes.

This repository is the **harness only** (the client side). It is laid out to mirror a larger
monorepo (`src/build/...`) so it can be consumed by monorepo-style builds, and it operates on a
**separate target repository** identified by `TARGET_REPO_DIR` (see
[`.claude/rules/pr-bot.md`](./.claude/rules/pr-bot.md) → "Harness vs. Target Repository").

### Layout
| Path | Purpose |
|------|---------|
| `src/build/pr-bot/` | The bot daemon + per-PR orchestrator (bash) |
| `src/build/shared/` | Shared ADO auth (`pat`/`entra-sp`/`entra-wi`) + API + worktree + logging helpers |
| `src/build/test/` | Self-contained unit tests (extract and exercise the real shipped functions) |
| `claude-pr-review-pipeline.yml` | ADO pipeline that AI-reviews **GitHub** PRs (separate from `azure-pipelines.yml`) |
| `src/build/github-pr-review.py` | GitHub PR-review poster — REST + GraphQL, stdlib-only Python |

### Stack & dependencies
- **Language:** Bash (4.3+). No package manifest. (One exception: `src/build/github-pr-review.py`,
  the CI-side GitHub review poster — stdlib-only Python, no pip deps.)
- **Runtime deps:** `git`, `curl`, `jq`, and the `claude` CLI (Claude Code).
- **Auth:** Azure DevOps via PAT, Entra service principal, or Workload Identity (`ADO_AUTH_METHOD`).
  The GitHub review pipeline authenticates as a separate **review bot** via `GH_REVIEW_PAT`, an
  ADO **pipeline** secret — never committed (set on the build definition; see Secrets below).

---

## Quick Start

```bash
# 1. Configure (never commit the result — config.env is gitignored)
cp src/build/pr-bot/config.env.example src/build/pr-bot/config.env
$EDITOR src/build/pr-bot/config.env       # set TARGET_REPO_DIR, ADO_ORG/PROJECT/REPO, NTFY_URL
# put secrets (ADO_PAT, ANTHROPIC_AUTH_TOKEN, …) in src/build/pr-bot/.secrets.env (gitignored)

# 2. Install + start the systemd user service
./src/build/pr-bot/install-service.sh
systemctl --user restart pr-bot && journalctl --user -u pr-bot -f
```

Full configuration reference: [`src/build/pr-bot/docs/setup-guide.md`](./src/build/pr-bot/docs/setup-guide.md).

---

## Secrets & Configuration (IMPORTANT — public repo)

This is a **public** repository. Never commit secrets or environment-specific values:

- **Secrets** → `src/build/pr-bot/.secrets.env` (gitignored): `ADO_PAT`, `ANTHROPIC_AUTH_TOKEN`,
  `AZURE_CLIENT_SECRET`, etc.
- **Runtime config** → `src/build/pr-bot/config.env` (gitignored). Only `config.env.example`
  (placeholders) is committed.
- **State** → `.pr-bot-state/` (gitignored): locks, leases, worktrees, logs.
- **CI-only secret** → `GH_REVIEW_PAT` (the GitHub review bot's fine-grained PAT) lives **only**
  as an ADO **pipeline** secret variable on the `left-jab-harness-review` definition — it is
  **never** committed and never written to disk in this repo.
- The root [`.gitignore`](./.gitignore) enforces all of the above. When in doubt, run a secret
  scan (`gitleaks detect --no-git`) before pushing.

---

## Topic Index

| Rule file | Loads when you touch… | Covers |
|-----------|----------------------|--------|
| [`pr-bot.md`](./.claude/rules/pr-bot.md) | `src/build/pr-bot/**` | Harness vs. target repo, markers (`[no-auto]`/`[no-bot]`), four-layer OOM protection, ntfy stream resilience, router exit-code contract (incl. `exit 75` yield), self-healing, concurrency stand-down |
| [`ci-review.md`](./.claude/rules/ci-review.md) | `claude-pr-review-pipeline.yml`, `src/build/github-pr-review.py`, `src/build/test/github-pr-review-test.sh` | CI-side Claude PR review for **GitHub** — pipeline structure, the poster's 7-step flow, ADO→GitHub API mapping (REST + GraphQL), YAML gotchas, first-Python-in-repo notes |

---

## Architecture & Server-Side Context

A high-level architecture overview lives in [`ARCHITECTURE.md`](./ARCHITECTURE.md).

This harness is the **client side** of a larger design. The **server-side** components (event
relay, containerization, daemonset/Helm, multi-tenant resource provider, billing, gateway) are
specified separately and are **maintained in the private Finistack monorepo** under
`docs/specs/2026-06-pr-bot-daemonset/`. Those engineering specs are the source of truth for the
server side and are **referenced, not duplicated, here** — do not copy their contents into this
public repo.

---

## Contributing

- Keep changes harness-scoped; this repo intentionally contains no other-service code.
- **Lint:** `shellcheck src/build/**/*.sh` must pass.
- **Test:** run the bash suites in `src/build/test/` (they need no live services).
- Follow the existing exit-code and marker contracts documented in
  [`.claude/rules/pr-bot.md`](./.claude/rules/pr-bot.md) — they are load-bearing for the
  crash/circuit/lease machinery.
