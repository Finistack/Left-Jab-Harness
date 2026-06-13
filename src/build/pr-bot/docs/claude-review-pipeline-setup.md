# Claude PR Review Pipeline Setup (GitHub-targeting)

This repo ships a **second** Azure DevOps pipeline,
[`claude-pr-review-pipeline.yml`](../../../../claude-pr-review-pipeline.yml), that runs an
**AI code review** on GitHub pull requests and posts findings back to the PR. It is the
GitHub-retargeted sibling of the monorepo's ADO review pipeline, and is **separate** from
the lint/test/build pipeline ([`azure-pipelines.yml`](../../../../azure-pipelines.yml),
definition `left-jab-harness`).

> Flow: **GitHub PR → ADO pipeline → `claude -p` (diff) → `github-pr-review.py` →
> GitHub PR** (inline comments / thread resolve / approve). See
> [`ARCHITECTURE.md`](../../../../ARCHITECTURE.md) → "CI-side: Claude PR review (GitHub)".

The poster ([`src/build/github-pr-review.py`](../../github-pr-review.py)) is **stdlib-only
Python** (`urllib`): it reads review threads via one **GraphQL** query (authoritative for
resolution state + thread node-ids) plus REST `issues/{n}/comments` (PR-level notes), and
writes via **REST** (inline comments, PR-level notes, thread resolve/unresolve, approval).

---

## Why a separate bot account (read first)

The pipeline casts a real GitHub **`APPROVE`** review when a PR is clean — the parity
analogue of the ADO poster's `vote=10`. GitHub **forbids self-approval** (`422
Unprocessable Entity` if the token's user authored the PR), so the approval must come from
a **distinct** identity. That identity also needs **Write** access for its approval to
count toward branch protection's required-approval gate.

Hence: a dedicated **review bot account** with its own **fine-grained PAT**, added as a
**Write collaborator** on this repo. This is intentionally a *different* account from the
autonomous Left Jab Bot (which drives ADO, not GitHub).

---

## 1. USER: create the bot account + token (manual, out-of-band)

These steps mint a credential and **cannot** be done from this repo; do them by hand:

1. **Create a GitHub account** for the bot (e.g. `finistack-review-bot`). Use a distinct
   email; enable 2FA.
2. **Add it as a Write collaborator** on `Finistack/Left-Jab-Harness`:
   *Repo → Settings → Collaborators → Add people →* the bot login *→ Role: **Write*** →
   then **accept the invite** from the bot account (Settings → invitations, or the email).
   Write (not Maintain/Admin) is the least privilege whose approval still satisfies the
   gate.
3. **Mint a fine-grained PAT** owned by the **bot** account
   (*bot's Settings → Developer settings → Fine-grained tokens → Generate*):
   - **Resource owner:** `Finistack`
   - **Repository access:** *Only select repositories* → **`Left-Jab-Harness`** only.
   - **Repository permissions:** **Pull requests → Read and write** (sufficient for
     comments, thread resolution, and submitting the approval review). Everything else
     **No access**. (Contents stays *No access* — the pipeline checks out via the ADO
     `GitHub-LeftJab` connection, not this PAT.)
   - **Expiration:** the shortest your rotation cadence allows; calendar a renewal.
4. **Hand off out-of-band** (not in a PR, issue, or commit): the **PAT** and the bot's
   **login**. The PAT goes into a *secret* pipeline variable in step 2 below.

> The PAT is a credential: never paste it into the repo, a PR, ADO logs, or shell history.
> `.gitignore` already covers `.secrets.env`/`config.env`/`*.log`, but this token lives in
> the **ADO pipeline**, not on disk.

---

## 2. ASSISTANT: provision the pipeline (`az` CLI)

The variable group **`Build Pipelines`** (id `1`) already carries the `ANTHROPIC_*` vars;
the new definition only needs the two GitHub variables plus authorization to that group and
the `GitHub-LeftJab` service connection.

```bash
ORG="https://dev.azure.com/<your-ado-org>"
PROJECT="<your-ado-project>"
GH_CONN_ID="<GitHub-LeftJab service-connection id>"

# Create the definition (skip the first auto-run; we run it against a real PR later).
az pipelines create \
  --name "left-jab-harness-review" \
  --repository "https://github.com/Finistack/Left-Jab-Harness" \
  --branch main \
  --yml-path claude-pr-review-pipeline.yml \
  --service-connection "$GH_CONN_ID" \
  --org "$ORG" --project "$PROJECT" \
  --skip-first-run true

PIPE_ID="$(az pipelines show --name left-jab-harness-review --org "$ORG" --project "$PROJECT" --query id -o tsv)"

# Bot identity (non-secret) + PAT (secret). Read the PAT from an env var; never inline it.
az pipelines variable create --name GH_BOT_LOGIN --value "<bot-login>" \
  --pipeline-id "$PIPE_ID" --org "$ORG" --project "$PROJECT"
az pipelines variable create --name GH_REVIEW_PAT --secret true --value "$GH_REVIEW_PAT" \
  --pipeline-id "$PIPE_ID" --org "$ORG" --project "$PROJECT"
#   (export GH_REVIEW_PAT=<token> first, in a shell whose history is off)
```

**Authorize the shared resources for the new definition.** A variable group and a service
connection must each grant the definition access. If the non-interactive CLI cannot set
pipeline authorization in your org, do it once in the UI:

- *Pipelines → Library → `Build Pipelines` → Pipeline permissions → +* → add
  `left-jab-harness-review`.
- *Project Settings → Service connections → `GitHub-LeftJab` → Security → Pipeline
  permissions → +* → add `left-jab-harness-review`.

```bash
# Run it against an OPEN PR branch to smoke-test (resource-authorization prompts surface here).
az pipelines run --name left-jab-harness-review \
  --branch "refs/pull/<PR_NUMBER>/merge" \
  --org "$ORG" --project "$PROJECT"
```

> The `pr:` block in the YAML is the real trigger (ADO registers a GitHub webhook through
> `GitHub-LeftJab`); `az pipelines run` is only for the initial smoke test.

---

## 3. Pipeline variables reference

| Variable | Where | Secret? | Purpose |
|----------|-------|---------|---------|
| `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL` | `Build Pipelines` group | token: **yes** | Claude CLI endpoint/auth/models (shared with the other pipelines). |
| `GH_REVIEW_PAT` | pipeline var | **yes** | Bot's fine-grained PAT (Pull requests: R/W, this repo only). Posts comments, resolves threads, casts `APPROVE`. |
| `GH_BOT_LOGIN` | pipeline var | no | Bot login; used for human-reply detection + dedup. Poster falls back to `GET /user` if unset. |
| `MAX_DIFF_BYTES` | YAML default (`400000`) | no | Upper cap on the diff sent to the reviewer; override on the definition if needed. |

The poster also consumes these **runtime macros** (set in the YAML `env:` blocks, not by
you): `GITHUB_REPOSITORY=$(Build.Repository.Name)`,
`PR_NUMBER=$(System.PullRequest.PullRequestNumber)`,
`HEAD_SHA=$(System.PullRequest.SourceCommitId)`,
`TARGET_BRANCH=$(System.PullRequest.TargetBranchName)`.

---

## 4. Branch protection (keep the review non-required)

Leave the review pipeline **non-required** — the GitHub analogue of the ADO original's
`isBlocking=false`. Do **not** add `left-jab-harness-review` to `required_status_checks`.
Merges stay gated by the existing **`left-jab-harness`** check + **1 approval** + **linear
history**.

> **Security note (flagged).** The bot's `APPROVE` satisfies the 1-approval gate, so a clean
> Claude run *can* let a PR merge with no human review when the required `left-jab-harness`
> check is green. Mitigations baked in: `enforce_admins=false` keeps a human admin in
> control; the bot **cannot** approve its own PRs (422), so any bot-authored PR still needs a
> human; and the required `left-jab-harness` check still blocks red builds.
>
> **Parity gap (matches the ADO original):** the bot does **not** auto-dismiss a stale
> `APPROVE` when a later push introduces findings. Optional hardening (not in parity scope):
> dismiss-stale-approvals on new commits, or require 2 approvals on sensitive paths via
> CODEOWNERS.

---

## 5. Verification (end-to-end)

1. Branch `test/review-smoke`, plant an **obvious in-diff bug**, open a PR to `main`.
2. Confirm `left-jab-harness-review` runs and posts an **inline** comment at the bug's
   `file:line` with the right label/body; `left-jab-harness` (lint/test/build) runs
   independently.
3. Reply to the thread as a **human** (non-bot), push a fix, re-run: the same finding is
   **not** re-posted (dedup), and the human-replied thread is **resolved** (GraphQL).
4. Push a clean commit → the bot **submits `APPROVE`** + posts the ✅ approved note; the
   approval counts toward the gate.
5. **422 fallback:** stage `[{"file":"README.md","line":99999,"severity":"info","comment":"x"}]`
   as `/tmp/review-results.json` and run the poster with the PR env → the inline POST 422s →
   it falls back to a **PR-level** note naming `` (`README.md:99999`) ``.
6. Confirm the PR still merges with the review check **present but not required**.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `422` on the approval review | The PAT's user authored the PR (self-approval), or the bot lacks Write | Bot-authored PRs need a human approver; verify the bot is a **Write** collaborator and accepted the invite. |
| Approval posts but doesn't count toward the gate | Bot has **Read** (not Write) access | Re-add as **Write** collaborator. |
| `403` with `Retry-After` mid-run | Secondary rate limit | The poster sleeps and retries automatically; large PRs also hit `MAX_INLINE_COMMENTS`. |
| Inline comment 422s for a valid file | `line` not on the diff's RIGHT side (context/deleted line) | Expected — the poster routes it to a PR-level fallback note. |
| Threads never auto-resolve | `GH_BOT_LOGIN` unset *and* `GET /user` failed | Set `GH_BOT_LOGIN`; resolution is fail-safe (skips) when the bot identity is unknown. |
| Pipeline didn't trigger on a PR | `GitHub-LeftJab` webhook not authorized for this definition | Authorize the connection for `left-jab-harness-review` (step 2). |
