---
paths:
  - "src/build/pr-bot/**"
---

# Left Jab Bot (PR Bot)

> Loaded when working in `src/build/pr-bot/**`. The bot drives Azure DevOps via the
> ADO REST API (PRs, threads, work items, builds) using a pluggable auth method
> (PAT / Entra service principal / Workload Identity).

The **Left Jab Bot** (systemd service: `pr-bot`) automatically addresses PR review comments, fixes failing builds, resolves merge conflicts, and manages work item linkage. It runs as a systemd user service on a host with a local clone of the **target** repository it services.

## Harness vs. Target Repository (read this first)

This repository contains the **harness** — the client-side bot scripts. The repository the
bot **operates on** (creates worktrees in, fetches, pushes, reads/writes PRs) is a **separate**
checkout identified by **`TARGET_REPO_DIR`** in `config.env`.

- `TARGET_REPO_DIR` → absolute path of a local clone of the repo to service. `pr_router.sh`
  resolves `REPO_ROOT` from it; `start.sh` resolves `TARGET_REPO_ROOT` (used for worktree GC).
- If `TARGET_REPO_DIR` is empty, both fall back to the git toplevel of the harness scripts —
  the legacy "harness lives inside the repo it services" behavior.
- The per-PR worktree **files** live under `.pr-bot-state/worktrees/` (inside the harness dir),
  but `git worktree add` registers them against the **target** repo's `.git`, so all worktree
  operations and GC must use the target root.

## User-Facing Name vs Machine Identifiers

- **Display name** (shown in PR comments): "Left Jab Bot" — e.g. `🤖 **Left Jab Bot Status**`, `⚠️ **Left Jab Bot**: Crashed on...`
- **Machine-readable markers** (used for parsing, never renamed): `pr-bot-status`, `pr-bot-lease`, `pr-bot-state`
- **systemd service name**: `pr-bot`
- **Config/state directory**: `.pr-bot-state/`

## Opt-Out Markers: `[no-auto]` and `[no-bot]`

Two independent, case-insensitive PR markers let a human dial back the bot. They are **complementary** — `[no-bot]` is a full standdown; `[no-auto]` only ungates the merge.

| Marker | Effect | Matcher | Use when |
|--------|--------|---------|----------|
| **`[no-auto]`** | Disables **only** auto-approve + auto-complete. Comment-fixing, build-fix, merge-conflict rebasing, and work-item linkage all still run; a human must approve & complete. | **Lenient** substring — fires anywhere in title/description, incl. combined tags like `[SPEC][no-auto]`. | Low-risk PR you still want the bot to maintain, but a human merges (e.g. PM spec PRs). |
| **`[no-bot]`** | **Full standdown** — no lease, worktree, fetch/rebase, or push. The bot never touches the PR. | **Strict** directive (`pr_text_has_directive`) — must start a line, not be backticked, so prose that *documents* the marker doesn't trip it. | A human/interactive agent is actively driving the branch. |

A `*-wip` source branch is treated like `[no-bot]` (Tier 2 standdown). PRs without either marker behave exactly as before.

- **Implementation:** `pr_router.sh` detects both before any side effects (early payload check + authoritative PR-details recheck). `[no-auto]` → `SKIP_AUTO=1`, threaded to `run_policy_gate` (5th arg) → `auto_approve_pr`/`auto_complete_pr`/`post_risk_assessment` in `pr_policies.sh` honor `skip_auto` via additive trailing params; the risk-assessment comment gains an "⏸️ Auto-merge disabled via `[no-auto]`" line. `[no-bot]` bails with `exit 0` (no crash marker, no circuit penalty).
- **Why the matcher asymmetry:** standing the bot *down* on the wrong PR is high-consequence, so `[no-bot]` uses the strict line-anchored matcher; merely leaving a low-risk PR for a human to merge is low-consequence, so `[no-auto]` uses a lenient substring (and must match `[SPEC][no-auto]`).
- **Caveat (chicken-and-egg):** the deployed bot snapshots its scripts at startup. A change to the `[no-auto]`/`[no-bot]` logic only takes effect after merge **and** `systemctl --user restart pr-bot`. So tagging the very PR that introduces/modifies this logic will **not** stop the currently running bot — protect that PR with a human watcher or pause the bot.

## Key Files

| File | Purpose |
|------|---------|
| `src/build/pr-bot/start.sh` | Main daemon — ntfy subscriber, concurrency limiter (`MAX_CONCURRENT`), memory admission + aggregate OOM guard (`check_resource_budget`, `kill_oversized_claudes`), crash recovery |
| `src/build/pr-bot/pr_router.sh` | Per-PR orchestrator — lock, lease, worktree, Claude invocation (`timeout … claude`) |
| `src/build/pr-bot/pr_lease.sh` | Distributed lease via ADO PR comments (CAS pattern) + dead-PID orphan reclaim |
| `src/build/pr-bot/pr_policies.sh` | Risk classification, auto-approve, auto-complete |
| `src/build/pr-bot/pr_analysis.sh` | Merge conflict detection and auto-rebase |
| `src/build/pr-bot/pr_workitems.sh` | Work item linkage and creation |
| `src/build/pr-bot/pr-bot.service` | systemd unit — `MemoryMax=3G`, `KillMode=control-group` (one breach OOM-kills the whole bot) |
| `src/build/pr-bot/install-service.sh` | Install/reinstall systemd service |
| `src/build/pr-bot/config.env` | Runtime configuration (`TARGET_REPO_DIR`, auth, `NTFY_URL`, `MEMORY_BUDGET_MB`, `MAX_CONCURRENT`, etc.) — gitignored; copy from `config.env.example` |
| `src/build/shared/ado_auth.sh` | Pluggable ADO auth — `pat`, `entra-sp`, `entra-wi` |
| `src/build/shared/ado_api.sh` | Shared `ado_api_call()` with retry/backoff |

## Deploying Changes

**IMPORTANT**: The pr-bot systemd service runs the harness scripts from this repo's checkout
and services the repo at **`TARGET_REPO_DIR`**. The harness checkout can be on any branch
(it only runs the scripts on disk at startup); the **target** checkout's branch does not
matter to the bot because it operates through `git worktree` against the target's remote.

### Post-Change Deploy (normal)

After harness changes are merged (or applied on disk):

```bash
# 1. Update the harness checkout
git pull

# 2. Restart the service (it reads scripts from disk at startup)
systemctl --user restart pr-bot

# 3. Verify
systemctl --user status pr-bot
journalctl --user -u pr-bot -f
```

### Pre-Merge Hotfix Deploy (urgent)

When you need to deploy a fix immediately before the PR merges (e.g., the bot is actively
creating duplicates), apply just the changed file(s) on disk and restart — the bot reads
scripts from disk at startup, so an uncommitted working-tree change is enough:

```bash
git checkout <fix-branch> -- src/build/pr-bot/<changed-file>.sh
systemctl --user restart pr-bot
journalctl --user -u pr-bot -f
```

### Deploying from a Worktree

When Claude Code runs in a worktree (`.claude/worktrees/...`), edits are isolated from the
running checkout. Copy the changed file(s) into the running harness directory and restart:

```bash
cp src/build/pr-bot/<changed-file>.sh <harness-checkout>/src/build/pr-bot/<changed-file>.sh
systemctl --user restart pr-bot
```

The snapshot mechanism regenerates on startup, picking up the new files.

## Crash Recovery

When `pr_router.sh` exits non-zero, `cleanup()` writes a `.crashed` marker file to `$STATE_DIR/pr-<ID>.crashed`. On next startup, `recover_crashed_prs()` in `start.sh`:
1. Waits for the lease to expire (avoids conflicting with active processing)
2. Re-checks for active leases (skips if another bot took over)
3. Posts a crash notice on the PR status thread
4. Deletes the `.crashed` file

## Memory Management & OOM Protection

The bot runs under a systemd cgroup with **`MemoryMax=3G`** and **`KillMode=control-group`**. The kill mode is the critical constraint: if **any** process in the cgroup breaches 3G, systemd OOM-kills the **entire bot** (every in-flight router at once), not just the offending Claude. So the app must keep total memory *below* the wall on its own.

Four layers defend against OOM (in `start.sh`):

1. **Structural admission cap (the load-bearing one).** Before dispatching a router, `start.sh` enforces `MAX_CONCURRENT` (default **2**) and `check_resource_budget`. Per-PR memory is estimated by `estimate_pr_weight` → `weight_to_mb` (**SMALL=700, MEDIUM=1100, LARGE=1600 MB**). These reflect the *real* mature `claude --print` footprint (~0.8–1.2 GB), measured live. The admission budget is `MEMORY_BUDGET_MB=2700` (~370 MB under the 3G wall) minus `RESERVED_OVERHEAD_MB=300`. Two MEDIUM sessions (2×1100+300=2500) fit; a third (3600) is deferred to the queue.

2. **Per-process watchdog (Pass 1 of `kill_oversized_claudes`, runs every ~60s).** Kills any single handler whose **full-subtree** RSS exceeds its weight estimate + 50% headroom (a leaking/runaway session).

3. **Aggregate guard (Pass 2).** Even if every session is under its own limit, their *sum* can breach the cap. When the **authoritative cgroup `memory.current`** crosses a 90%-of-budget high-water (2430 MB), it sheds the **youngest** handler's whole subtree (least work lost; its lease stays active so a later heartbeat re-dispatches it once there is headroom). It never kills the last remaining handler.

4. **Orphan-subprocess reaper (`reap_orphaned_subprocesses`, runs every ~60s + on-demand).** The first three layers all key off **`ACTIVE_PIDS`** (the tracked router subtrees), so they are *structurally blind* to memory held by processes that are in the cgroup but descend from **no** tracked router. That blind spot is real: Claude workers shell out to subprocesses (e.g. cloud CLIs in python), and when a router's session ends abnormally (timeout / OOM-shed / kill) some grandchildren **reparent to the systemd `--user` manager** (the daemon's parent) yet **stay inside the `pr-bot.service` cgroup**, so they keep counting against `memory.current`. Left unchecked they accrete (~1.3 GB over 2 days) until `check_resource_budget` defers **all** dispatch with `ACTIVE_PIDS` **empty** — a **wedge**: Pass-1/Pass-2 have nothing to act on, the deferred queue grows unbounded, and the bot does zero useful work while still reporting `active (running)`. The reaper closes the gap by reading the cgroup's authoritative process set (`cgroup.procs`) and diffing it against the **daemon's own process subtree** (`subtree($$)`): anything in-cgroup, **off** that subtree, older than `ORPHAN_REAP_AGE_SECS`, and not comm-denylisted is a leaked orphan and gets its whole subtree `TERM`/`KILL`ed. It fires on the 60s maintenance tick and on stream-disconnect, **and** immediately on the defer path when the budget is exhausted *with zero active handlers* (the exact wedge signature, throttled ~30s) so dispatch recovers the same cycle instead of deferring into the deadlock.

   > **Why a denylist + age gate, not just "off-tree".** Detached git/credential housekeeping (`git gc --auto`, `git-maintenance`, `git-repack`, `fsmonitor--daemon`, credential/gpg/ssh helpers) can briefly leave the daemon's subtree while staying in-cgroup — a legitimate transient, not a leak. `ORPHAN_REAP_COMM_DENYLIST` (prefix-matched, robust to /proc's 15-char `comm` truncation) spares those families, and `ORPHAN_REAP_AGE_SECS` (default **180s**) ensures only *persistent* off-tree procs are reaped, never a freshly-forked legit grandchild not yet visible in the subtree snapshot. `cgroup.procs` is read **before** the subtree (closes the TOCTOU window), and the reaper never touches `$$` itself or PID 1.
   >
   > **Inspect before you trust it:** `./start.sh --reap-orphans-dryrun` resolves the **live** daemon via its PID file, reads that daemon's real cgroup, and prints `pid comm age_s rss_mb` for every proc it *would* reap (plus total reclaimable MB) — **no kills**. On a healthy bot it reports 0 candidates. The dry-run and the live reaper call the **same** predicate (`_select_orphan_candidates`), so "what it would reap" can never drift from "what it reaps". (Unit-tested end-to-end in `src/build/test/orphan-reaper-test.sh`, which extracts and exercises the real shipped functions.)

**Tuning** (all overridable in `config.env`, no redeploy needed): `MEMORY_BUDGET_MB`, `MAX_CONCURRENT`, `RESERVED_OVERHEAD_MB`, `CLAUDE_TIMEOUT`; reaper knobs `ORPHAN_REAP_ENABLED` (default `true`), `ORPHAN_REAP_AGE_SECS` (default `180`), `ORPHAN_REAP_GRACE_SECS` (default `5`), `ORPHAN_REAP_COMM_DENYLIST`. If you change `MemoryMax` in `pr-bot.service`, keep `MEMORY_BUDGET_MB` ~300–400 MB **under** it.

> **External safety net.** Even with the reaper, a never-anticipated wedge variant should not strand the bot. A separate watchdog timer can classify a `pr-bot` showing many `🛑 Memory budget … deferring` lines with **zero** throughput as `WEDGED` and restart it. The reaper is the root-cause fix; such a doctor is belt-and-suspenders.

### macOS Pressure Gate (Darwin only)

The cgroup OOM machinery above is Linux-only. On macOS the bot shares the machine with the
user's apps and the real killer is the kernel's jetsam. `SYSTEM_PRESSURE_GATE_ENABLED` (default
`true`) defers a **new** dispatch only when the system is genuinely about to kill processes —
`kern.memorystatus_vm_pressure_level` at/above `SYSTEM_PRESSURE_LEVEL_THRESHOLD` (default **4**;
macOS levels: 1=normal, 2=warn, 4=critical). Defaulting to **4** is deliberate: the kernel
reports level 2 constantly on a busy desktop just to ask apps to drop caches — it does **not**
jetsam-kill at 2 — so gating on 2 throttles the bot to 1-at-a-time for no reason. Unit-tested in
`src/build/test/pressure-gate-test.sh`.

### ntfy Event Stream Resilience

Instant PR events arrive over a persistent `curl -s --no-buffer --keepalive-time 30 "$NTFY_URL/$TOPIC/json"` stream feeding the main `read` loop in `start.sh`. If the stream dies, the outer `while true` reconnects with exponential backoff (`RECONNECT_DELAY` 2s→`MAX_RECONNECT_DELAY` 300s). When this path wedges, the bot does **not** go down — the heartbeat (`HEARTBEAT_INTERVAL_SECS`, default 300s) still re-dispatches every actionable PR, so work continues with up-to-5-minute latency. That masking is exactly why a wedged stream is easy to miss.

**The bash `read` exit-code contract (do not get this backwards):** `IFS= read -r -t "$NTFY_READ_TIMEOUT" msg` returns **`0`** = a line was read, **`1` (more generally `1..128`)** = **EOF** (the curl/stream closed → you MUST break out and reconnect), and **`>128`** (e.g. `142`) = the `-t` **timeout** fired (the stream is still open, just idle → keep waiting). A historical guard `while read … || [ $? -le 128 ]` had this **inverted**: on EOF it *continued* (re-reading a closed pipe in a ~30% CPU tight spin that never reached the reconnect code), and on a healthy idle timeout it *exited* (needlessly tearing down a live stream). Capture the code explicitly under `set +e`/`set -e` and branch on it — never rely on a single `-le 128` test.

**Stall watchdog for half-open sockets.** A dropped TCP connection can leave the socket half-open so `read` never gets EOF and never times out into a reconnect. `NTFY_STALL_SECS` (default **300s**) tracks the last line received (any line, including ntfy keepalives) and forces a reconnect if the stream goes silent for that long. `NTFY_READ_TIMEOUT` (default **60s**) is the inner wake cadence. Both are env-overridable.

**Diagnosing a wedge:** the tell is a `start.sh --service` main-loop PID burning steady CPU (e.g. 30%) with **no** `curl …/$TOPIC/json` child process and **no** recent `📨 Received PR event` lines, while heartbeat dispatches continue. Confirm with `pgrep -af 'curl.*<topic>/json'` (should always be exactly one) and by sampling the main-loop PID's `%cpu`. A `systemctl --user restart pr-bot` clears it, but the real fix is the correct exit-code branch above.

> **CRITICAL — measure the full process subtree, not depth-1.** Claude is launched as `( pr_router.sh ) & → subshell-bash → pr_router-bash → timeout → claude → {node, MCP}`. The memory-heavy processes sit at **depth 2–4**. A naive `pgrep -P "$pid"` (depth-1) walk stops at the ~16 MB `timeout` wrapper and misses the ~600 MB+ claude subtree — a **~39× under-count** that silently disables admission *and* both watchdog passes. Any code that sums RSS or kills a handler MUST use the recursive helpers (`_collect_subtree_pids`, `_subtree_rss_mb`, `_kill_subtree`) or read the cgroup directly (`get_cgroup_mem_mb`). Likewise, `kill`-ing the tracked subshell PID does **not** propagate to the `timeout→claude` children — they reparent to init and keep consuming cgroup memory — so always kill the **whole subtree**.

## Router Exit-Code Contract (CRITICAL)

`cleanup()` is an `EXIT` trap whose **first line** captures `exit_status=$?`. Every downstream recovery decision keys off that single number: `0` → `circuit_record_success` + lease released `done` + no `.crashed` marker + parent logs "✅ completed successfully"; non-zero → `circuit_record_failure` (breaker backs off) + lease released `failed` + `.crashed` marker written + recovery re-queues. **So `pr_router.sh` MUST end with an explicit `exit` mirroring the verdict** — `exit 0` only when `CLAUDE_SUCCESS=true`, else `exit 1`. The trap can only report the truth if the script *tells* it the truth via `$?`.

> **Guardrail:** never let a control path in `pr_router.sh` reach EOF implicitly — a trailing `log` (or any successful builtin) resets `$?` to 0 and silently lies to the breaker. This also interacts with the per-session memory floor: legitimately heavy work that balloons to ~2 GB is **correctly** shed by Pass-1, but that shed is a *failure* of that run — the exit code must be non-zero or the breaker never backs off and the work re-balloons forever.

### The third state — `exit 75` (YIELD / `EX_TEMPFAIL`)

Beyond `0` (success) and `1` (failure) there is a **third** terminal code: **`75` = yield**, emitted when the router did real work but lost a **push race** to a concurrent human/agent driving the same branch (see "Concurrency Stand-Down" below). It is deliberately distinct because contention is **not a defect** and must not be punished like one. `cleanup()` maps `75` specially:

- **No circuit penalty** — `circuit_record_failure` is *skipped* for `75` (the gate `&& [ "$exit_status" -ne 75 ]`), so a healthy PR isn't backed off just because a human pushed mid-run.
- **No `.crashed` marker** — the marker block also excludes `75`; a yield self-recovers.
- **Lease released as `done` (not `failed`)** — `done` is treated as **non-active** by the lease filter, so `pr_heartbeat.sh` sees no active lease + still-actionable work and **re-dispatches on its next cycle (~5 min)**. `done` (vs `failed`) also avoids posting a scary visible ⚠️ comment for benign contention.
- **Parent logs a 🤝 yield**, not a ⚠️ crash or a ✅ success — `reap_jobs` in `start.sh` has a dedicated `true_rc -eq 75` branch.

## Self-Healing After an OOM/SIGKILL

A cgroup OOM (or any SIGKILL) tears a router down **without** running `cleanup()`, so it leaves two kinds of orphaned state that make a PR "**appear to wait**" while nobody is processing it:

- **Orphaned per-PR lock** (`$STATE_DIR/pr-<ID>.lock`, a dir with a `pid` file). `pr_router.sh` reclaims it **immediately** when the holder PID is dead (liveness via `kill -0`), rather than waiting out the old `CLAUDE_TIMEOUT+60` (~31 min) age timer.
- **Orphaned ADO lease** (`<!-- pr-bot-lease:{...} -->` comment). `check_pr_lease()` in `pr_lease.sh` treats a lease as reclaimable when it is **on our host** and the holder PID is dead — re-acquiring now instead of waiting the full ~30-min lease TTL. **Cross-host leases are never probed** (you can't `kill -0` a PID on another machine), preserving distributed-lease safety.

Both reclaims fire on the **next event** for that PR (heartbeat re-queue or a new webhook).

## Avoiding the Lease-Comment Self-Trigger Loop

The bot authenticates as a single identity, and a router **edits its own lease/status comment** on every run. ADO emits a `ms.vss-code.git-pullrequest-comment-event` ("edited a pull request comment") for each self-edit, which flows back through ntfy as a new webhook with a **fresh `notificationId`** (so the dedup log can't catch it). Acting on it just re-stamps the lease → another edit event → a **tight CPU loop** (observed: 54 dispatches in 11 min on one PR, which "appears stuck" while doing nothing).

The guard is a **zero-API intake filter** in `start.sh` (mirrored as defense-in-depth in `pr_router.sh` for the deferred-queue replay path): if `.resource.comment.content` contains a bot-internal machine marker (`pr-bot-lease` or `pr-bot-status`), the event is dropped before dispatch. Human and review-pipeline comments never carry these markers, so they still dispatch normally. **Any future code that posts/edits bot-authored PR comments must use a recognizable marker** so this filter keeps the bot from reacting to its own writes.

## Concurrency Stand-Down (Humans/Agents Co-Driving a Branch)

The bot's worktree is filesystem-isolated, but it checks out the **same source branch** and pushes to the **same remote ref** as a human or interactive agent working that PR. The collision is therefore at the **ref/push level**: the bot's recovery push could clobber a commit someone pushed seconds earlier. Three cooperating layers de-risk this:

1. **Tier 1 — `[no-bot]` full stand-down.** If the PR **title or description** carries `[no-bot]` **as a directive** (the marker at the start of a line — optionally after a list/quote bullet — *not* backticked or buried mid-sentence; matched by `pr_text_has_directive`, case-insensitive), the router bails at the **earliest possible point** (before the per-PR lock, lease, or worktree — before the `EXIT` trap is even armed) with `exit 0`: no lease, no worktree, no push, no circuit state. A best-effort check reads the webhook payload first; an **authoritative re-check** runs after `PR_DETAILS` is fetched (still before lease/worktree) to catch comment-event payloads that omit the title. `pr_heartbeat.sh` applies the same skip. **The directive-not-prose match is deliberate:** a bare substring grep false-fires on any PR that merely *documents* the marker — e.g. this feature's own PR title.

2. **Tier 2 — `*-wip` branch skip.** A source branch ending in **`-wip`** (configurable via `PR_BOT_WIP_SUFFIX`, default `-wip`) is treated as a human/agent scratch ref: the bot skips it (router `exit 0`, and heartbeat skip). Matching is a **suffix** test — `wip-feature` and `feature-wip-x` do **not** match; only `feature-wip` does.

3. **Push safety — `--force-with-lease` + rebase + bounded retry → yield.** The recovery push uses **`--force-with-lease`** (not a bare force-push), so it only overwrites the remote ref if it still points where the router's last fetch saw it. If a concurrent push moved it, git **rejects** instead of clobbering; the router then **fetch + rebase**es its commits on top and retries, up to **`PR_BOT_PUSH_RETRIES`** times (default **2**). If still contended after the budget (or the rebase conflicts), it **yields via `exit 75`** rather than fight — freeing the slot while the heartbeat re-dispatches ~5 min later.

   > **Error classification:** The retry loop distinguishes **concurrency rejections** (git stderr containing `stale info`, `failed to push`, `non-fast-forward`, etc.) from **non-transient errors** (expired credential, branch-policy rejection, network outage). Only concurrency rejections trigger rebase+retry and the yield path (exit 75); non-transient errors fall through to `exit 1` so the circuit breaker engages.

**Tunable knobs** (env / `config.env`, no redeploy of logic needed): `PR_BOT_WIP_SUFFIX` (default `-wip`), `PR_BOT_PUSH_RETRIES` (default `2`). The yield backoff is governed by `HEARTBEAT_INTERVAL_SECS` (~300 s).

## Common Operations

```bash
# Restart after code changes
systemctl --user restart pr-bot

# View live logs
journalctl --user -u pr-bot -f

# Check status
systemctl --user status pr-bot

# Clean stale locks (if bot is stuck)
rm -rf src/build/pr-bot/.pr-bot-state/pr-*.lock

# Reinstall service (after changing systemd unit or config)
./src/build/pr-bot/install-service.sh

# Check live memory vs the 3G wall (watch for peak nearing 3072 MB)
systemctl --user show pr-bot -p MemoryCurrent -p MemoryMax -p MemoryPeak

# Was the bot OOM-killed? (look for "oom" / "Killed process" / cgroup memory events)
journalctl --user -u pr-bot --no-pager | grep -iE 'oom|killed process|memory guard|shedding'

# Count live Claude sessions (should be <= MAX_CONCURRENT; >50MB = real worker, not launcher)
pgrep -af 'claude --print'

# Inspect what the orphan reaper WOULD reap (no kills)
./src/build/pr-bot/start.sh --reap-orphans-dryrun
```
