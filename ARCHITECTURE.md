# Architecture

Left Jab is a **client-side harness** that turns PR events on an Azure DevOps repository into
autonomous Claude Code runs, then writes the results back to the PR. It is a bash daemon with no
server of its own — it subscribes to a push-notification stream and drives the ADO REST API.

## Event flow

```
ADO PR comment / build / push
        │  (service hook)
        ▼
   ntfy topic  ──persistent stream──►  start.sh (daemon)
                                          │  intake filter (drop bot's own marker edits)
                                          │  concurrency + memory admission
                                          ▼
                                     pr_router.sh  (one per PR)
                                          │  per-PR lock  →  distributed lease (ADO comment)
                                          │  git worktree add (against TARGET repo)
                                          ▼
                                  timeout … claude --print   (does the work)
                                          │  policy gate (risk → auto-approve → auto-complete)
                                          ▼
                                  git push --force-with-lease  →  resolve threads  →  release lease
```

Background loops in `start.sh`:
- **Heartbeat** (`pr_heartbeat.sh`, ~5 min) re-dispatches any PR with actionable work and no active
  lease — the safety net when the live stream wedges.
- **Maintenance tick** (~60 s) runs the OOM watchdogs, the orphan-subprocess reaper, and stale
  worktree GC.

## Key design properties

| Property | Where | Why |
|----------|-------|-----|
| **Harness/target decoupling** | `TARGET_REPO_DIR` → `REPO_ROOT` (`pr_router.sh`), `TARGET_REPO_ROOT` (`start.sh`) | The harness runs from its own checkout but services a *separate* repo. |
| **Pluggable auth** | `shared/ado_auth.sh` (`pat` / `entra-sp` / `entra-wi`) | No hardcoded credentials; works with PATs or federated identity. |
| **Distributed lease** | `pr_lease.sh` (CAS on an ADO PR comment) | Multiple hosts can run the bot without double-processing a PR. |
| **Four-layer OOM protection** | `start.sh` | A `KillMode=control-group` cgroup means one breach kills the whole bot, so total memory must stay under the wall. |
| **Exit-code contract** | `pr_router.sh` `cleanup()` trap; `0`/`1`/`75` | Drives the circuit breaker, lease state, and crash recovery — the verdict must be told truthfully via `$?`. |
| **Concurrency stand-down** | `[no-bot]` / `*-wip` / `--force-with-lease`+rebase→`exit 75` | The bot yields instead of clobbering a human/agent co-driving the same branch. |
| **Self-trigger guard** | intake filter on `pr-bot-lease`/`pr-bot-status` markers | The bot edits its own status comment; without the filter that edit-event would loop. |

Full operational detail (memory layers, the `read` exit-code contract, marker semantics, yield
handling, self-healing after OOM) is in [`.claude/rules/pr-bot.md`](./.claude/rules/pr-bot.md).

## CI-side: Claude PR review (GitHub)

Separate from the client-side daemon above, the repo ships a **CI-side** AI reviewer: an
Azure-DevOps-built pipeline that reviews **GitHub** pull requests and writes findings back to
the PR. The daemon *services* an ADO repo from a long-running host; this pipeline *reviews* a
GitHub PR per build and exits.

```
GitHub PR  ──webhook──►  ADO pipeline (claude-pr-review-pipeline.yml)
                              │  git diff origin/<target>...HEAD
                              ▼
                         claude -p (diff)  ──JSON──►  github-pr-review.py
                                                          │  REST writes + GraphQL thread state
                                                          ▼
                                        GitHub PR  (inline comments / resolve / approve)
```

| Property | Where | Why |
|----------|-------|-----|
| **Separate pipeline** | `claude-pr-review-pipeline.yml` (definition `left-jab-harness-review`) | Distinct from the lint/test/build pipeline; the `pr:` block is its trigger (a GitHub webhook via the ADO connection). |
| **GitHub thread model** | `github-pr-review.py` | Resolution state + thread node-ids are **GraphQL-only**; bodies/paths/authors come over REST. Writes are REST; correlation is `databaseId == REST id`. |
| **Separate bot identity** | `GH_REVIEW_PAT` (ADO pipeline secret) | A clean review casts a real `APPROVE`; GitHub forbids self-approval (422), so a distinct **Write**-collaborator bot account is required. |
| **Non-blocking** | never submits `REQUEST_CHANGES`; review check left non-required | Mirrors the ADO original's `isBlocking=false`; merges stay gated by the existing required check + human approval. |

Full detail — the 7-step poster flow, the ADO→GitHub API mapping, and YAML gotchas — is in
[`.claude/rules/ci-review.md`](./.claude/rules/ci-review.md); provisioning (bot account, PAT,
`az` steps, branch protection) is in
[`src/build/pr-bot/docs/claude-review-pipeline-setup.md`](./src/build/pr-bot/docs/claude-review-pipeline-setup.md).

## Server side (out of scope for this repo)

The event relay, container image, daemonset/Helm chart, multi-tenant resource provider, auth
gateway, and billing are **separate server-side components**. Their engineering specifications are
maintained in the private Finistack monorepo under `docs/specs/2026-06-pr-bot-daemonset/` and are
**referenced, not reproduced** here. This repository deliberately contains only the client-side
harness.
