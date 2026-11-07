# Self-hosted CI prerequisites

Both Azure Pipelines use a trusted, persistent Linux pool. Configure this non-secret
variable on **each** build definition before using the YAML:

| Variable | Value |
| --- | --- |
| `selfHostedPool` | Name of the already-authorized self-hosted pool |

Pool names, endpoints and credentials do not belong in this public repository. A missing
pool variable must not silently select a hosted agent. Both pipelines use the static
`Agent.OS -equals Linux` demand and the fail-closed tool and endpoint checks below. Select
a pool whose Linux agents meet this contract; future agents must meet it too.

Do not put a variable macro around a complete capability demand: Azure DevOps can treat
that macro as a literal demand at admission, even when a YAML preview succeeds. Definition
variables are also unavailable in the attempted compile-time demand expression. Keep the
admission demand static and generic rather than adding site-specific capability names.

## Trust boundary

Keep fork PR builds disabled in the project's effective pipeline settings before selecting
a persistent pool. Verify `forkProtectionEnabled=true` and `buildsEnabledForForks=false`
in the effective `PipelineTriggerSettings` returned for each definition. Do not rely on
legacy `forks.enabled` alone. See Microsoft's
[effective trigger settings](https://learn.microsoft.com/en-us/javascript/api/azure-devops-extension-api/pipelinetriggersettings).
The normal same-repository PR triggers and scheduled/main image builds remain unchanged.

Workspace cleaning, random temporary directories and separate Docker endpoints prevent
accidental state reuse. They **do not sandbox malicious code** running under a shared OS
identity. Only trusted repository branches may run here. Do not enable fork execution as
part of pool setup, and do not grant a pipeline additional resources just to change pools.

## Agent contract

Provision the pool outside the pipeline. CI never uses `sudo apt` or global npm installs.

- Linux, Bash 4.3+, Git and Python 3.
- Lint/test job: ShellCheck (the verified baseline is 0.9.0), jq and the standard shell tools
  used by the self-contained suites.
- Image job: Docker CLI and Azure CLI. `DOCKER_HOST` must already select the assigned slot's
  private Unix socket. The resolved socket must be below the parent of `Agent.WorkFolder`
  (for example, a work folder `<slot>/_work` and socket `<slot>/docker-socket/docker.sock`).
  Shared system sockets, non-sockets, foreign-slot paths, absent endpoints and an overriding
  `DOCKER_CONTEXT` fail preflight. CI does not select or reconfigure the daemon.
- Review job: `UseNode@1` selects **Node.js 20.x**. The effective major is checked before npm
  installs the Claude CLI into job-local state. A preinstalled newer Node is not a substitute.
  The agent needs normal task-tool-cache access and access to the Node/npm downloads already
  required by the review pipeline.

## State and failure cleanup

Every job starts with a clean workspace and checkout. `src/build/ci-job.sh` creates an owned,
mode-0700 directory below `Agent.TempDirectory`. Review npm prefix/cache, Claude config, diff,
results and stderr are all isolated there. `REVIEW_FILE` points the existing Python poster
to this job's results. An artifact is published only after an output file has been written.
The review's existing nonblocking model-output behavior is unchanged.

Docker builds use a job-unique local tag. The existing publication step applies the semver,
source-commit and `latest` registry tags and records the refs it creates. Always-run cleanup
removes only those recorded refs still pointing to the job's image, plus its unique local
ref. It never prunes the daemon, force-removes image IDs or changes the inherited endpoint.
Docker config is job-local; the existing WIF login helper separately creates and removes its
private Azure/Docker authentication directory.

Cleanup runs after failures or cancellation when the agent is still able to execute tasks.
A killed agent or lost VM cannot guarantee final cleanup; normal pool maintenance must own
abandoned disk state and Docker build cache. Later jobs do not reuse a prior review's paths.

## Rollout and validation

1. Verify existing fork protections, pool authorization, required tools and private endpoints.
2. Set `selfHostedPool` on both definitions without adding credentials or changing permissions.
3. Validate both YAML files with Azure DevOps `previewRun: true`. This compiles YAML without
   queueing a run; it does **not** prove pool-variable resolution, agent admission or Docker
   endpoint selection inside a task.
4. After normal code review/publication, verify the actual next authorized build/review uses
   the intended pool and Linux agent. Check Node20, image tagging/push, review output artifact
   and final state cleanup. Never infer a live switch from a successful preview alone.
5. To roll back routing, restore the prior YAML through normal review. No host or permission
   changes are needed for this migration.

Local offline tests are `bash src/build/test/ci-job-test.sh` plus the other bash suites.
They mock Docker/model calls and do not build an image, install npm packages or post reviews.
