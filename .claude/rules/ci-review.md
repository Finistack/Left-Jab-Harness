---
paths:
  - "claude-pr-review-pipeline.yml"
  - "src/build/github-pr-review.py"
  - "src/build/test/github-pr-review-test.sh"
---

# CI-side Claude PR Review (GitHub)

> Loaded when working on the GitHub PR-review pipeline, its poster, or its test.
> This is the **CI-side** AI reviewer — distinct from the client-side autonomous
> daemon in [`pr-bot.md`](./pr-bot.md). The harness's lint/test/build pipeline
> (`azure-pipelines.yml`, definition `left-jab-harness`) is documented in
> [`pipeline-setup.md`](../../src/build/pr-bot/docs/pipeline-setup.md);
> provisioning the review bot is in
> [`claude-review-pipeline-setup.md`](../../src/build/pr-bot/docs/claude-review-pipeline-setup.md).

## What it is

A **separate** ADO pipeline (`left-jab-harness-review`) that reviews GitHub PRs and posts
findings back. It is the GitHub-retargeted sibling of the monorepo's ADO review pipeline —
same approach, same comment format, ADO REST swapped for **GitHub REST + GraphQL**.

```
GitHub PR → ADO pipeline → claude -p (diff) → github-pr-review.py → GitHub PR
                                                  (inline comments / resolve / approve)
```

| File | Role |
|------|------|
| `claude-pr-review-pipeline.yml` | The pipeline: Node + Claude CLI, compute diff, `claude -p`, run the poster, publish the artifact. |
| `src/build/github-pr-review.py` | The poster — stdlib `urllib` only; REST for writes, GraphQL for thread state. First Python file in this otherwise-bash repo. |
| `src/build/test/github-pr-review-test.sh` | Pure-function unit test; shells to `python3`, loads the hyphenated module via `importlib`. Auto-discovered by the CI `for t in src/build/test/*.sh` loop (no wiring change). |

## How it works

1. `git diff origin/$TARGET...HEAD` → `/tmp/pr-diff.txt` (10-byte floor skip, `MAX_DIFF_BYTES` upper cap).
2. Pipe the diff to `claude -p "<senior reviewer prompt>" --output-format json` (`|| true`).
3. `github-pr-review.py` parses the Claude envelope and runs the 7-step flow (below).

### The poster's 7-step flow (mirrors the ADO poster)

1. **Fetch threads** — one GraphQL query (`pullRequest.reviewThreads{ id isResolved comments{ databaseId body path author{login} } }`, paginated) + REST `GET issues/{n}/comments` for PR-level notes.
2. **Auto-resolve** — an unresolved Claude Review thread with any non-bot reply → `resolveReviewThread`. (Human-reply = non-`GH_BOT_LOGIN` author; replaces the ADO `BUILD_SERVICE_NAMES` check.)
3. **Dedup sets** — file-level + `(path, signature)` from threads *and* issue comments. `normalize_comment` strips the header, the severity prefix, **and** the `` (`path:line`) `` fallback marker so inline and fallback share one signature.
4. **Split** check_id vs regular issues; `meaningful_issues` filter verbatim.
5. **check_id** update/skip/create + resolve-stale (**dormant** — the harness prompt emits no `check_id` — but ported for parity).
6. **Post findings** — inline `POST pulls/{n}/comments {body, commit_id, path, line, side:RIGHT}`; on **422** fall back to a PR-level `issues/{n}/comments` note naming `` (`path:line`) ``; no-`line` findings post PR-level directly. Per-run cap `MAX_INLINE_COMMENTS`.
7. **Clean → approve** — `POST pulls/{n}/reviews {event:"APPROVE"}` as the **bot PAT** + a ✅ note. On approval failure, post the non-approved variant. **Never** `REQUEST_CHANGES` (keeps it non-blocking, like the ADO `isBlocking=false`).

## GitHub API mapping (the fidelity core)

| ADO behavior | GitHub replication |
|---|---|
| Fetch threads | GraphQL `reviewThreads` (state + node-id) + REST `issues/{n}/comments`. Correlate via `comments.databaseId == REST id`. |
| Close thread w/ human reply (status=4) | `resolveReviewThread(threadId)` (GraphQL-only). |
| File path `"/"+path` | **`lstrip('/')`** — GitHub paths have **no** leading slash (inverse of ADO). |
| Inline finding @ file:line | `POST pulls/{n}/comments` with `commit_id=HEAD_SHA`, `side:"RIGHT"`. |
| Line not in diff | **422** → PR-level fallback note (ADO never had this — GitHub only accepts lines on the diff). |
| Approve (`vote=10`) | `POST pulls/{n}/reviews {event:"APPROVE"}` as a **separate bot account** (self-approval is 422). |
| `BUILD_SERVICE_NAMES` author filter | `GH_BOT_LOGIN` (or `GET /user`) login compare. |
| check_id reactivate | `unresolveReviewThread` (inline only). |

Severity labels are identical: `critical→[HIGH]`, `warning→[MED]`, `info→[LOW]`; body is
`"{label} **[Claude Review - {SEV}]**\n\n{comment}"`.

All requests go through `urllib` with `Authorization: Bearer`, `Accept:
application/vnd.github+json`, `X-GitHub-Api-Version`, and a **`User-Agent`** (GitHub rejects
requests without a UA). Pagination is `?per_page=100&page=k` (REST) / cursor (GraphQL).

## YAML gotchas (this pipeline)

- **The `pr:` block IS the trigger.** `trigger: none` + `pr: { branches: include: [main] }`.
  ADO registers a GitHub webhook via the `GitHub-LeftJab` connection. This **diverges** from
  the monorepo original's `pr: none` (which relied on an ADO Build-Validation branch policy
  that GitHub lacks). Do not "fix" it back to `pr: none`.
- **`System.PullRequest.*` / `Build.Repository.Name` only in `env:` as `$(...)` runtime
  macros** — never in `${...}` compile-time expressions (they don't exist at parse time → parse
  error). The poster reads them from the environment.
- **`PR_NUMBER` = `System.PullRequest.PullRequestNumber`**, *not* `PullRequestId` (the latter
  is Azure-Repos-only and is empty for GitHub PRs).
- **No Python heredocs in YAML** — colons get parsed as YAML keys. The poster is a standalone
  `.py` for exactly this reason.
- **`fetchDepth: 0`** — the diff needs the merge base; a shallow clone breaks `origin/$TARGET...HEAD`.
- **`UseNode@1`** with `version:` (not the deprecated `NodeTool@0`).

## First-Python-in-repo notes

- **Stdlib only** (`urllib`, `json`, `re`, `os`, `time`) — no `pip install`. The CI agent has
  `python3`; `UsePythonVersion@0` is optional and intentionally omitted.
- The test runs **`python3 -m py_compile`** as a syntax guard, then asserts the **pure**
  functions (no network): `severity_label`, `normalize_comment`, `build_comment_body`,
  `normalize_path`, `extract_check_id`, `extract_review_from_claude_output`,
  `is_duplicate_comment`, `build_signatures`, `parse_fallback_location`,
  `select_threads_to_resolve`.
- The module name is **hyphenated**, so it can't be `import`ed by name — the test loads it via
  `importlib.util.spec_from_file_location`.

## Risks / edge cases

- **Non-JSON LLM output** → `extract_review_from_claude_output` → `[]` (no crash; the step is
  `|| true`).
- **Large diffs** → 10-byte floor + `MAX_DIFF_BYTES` cap + per-run `MAX_INLINE_COMMENTS` + a
  small inter-request sleep to dodge secondary-rate-limit 403s (honors `Retry-After`).
- **`commit_id` is mandatory** for inline comments — `HEAD_SHA` env, else `GET pulls/{n}.head.sha`.
- **`side:RIGHT` only** — deleted-line findings route to the fallback note.
- **Resolution is GraphQL-only** — REST cannot read or set `isResolved`.
- **No self-trigger loop** — the pipeline reacts to PR open/synchronize, not comment events, so
  the bot's own comments can't re-trigger it (unlike the daemon, which needs a marker filter).
- **Secret hygiene** — never log `GH_REVIEW_PAT` / `ANTHROPIC_*`; secret var + `env:` only.
  `.gitignore` already covers secrets/state/logs.
