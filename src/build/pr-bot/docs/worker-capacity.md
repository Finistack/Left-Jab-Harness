# Worker capacity and deployment verification

Tune the service cgroup and application watchdog together. Raising only one can
still terminate healthy sessions or let the service hit its hard memory limit.
Keep host headroom for CI jobs and retain bounded worker concurrency.

Example for a larger shared Linux runner, as a systemd service drop-in:

```ini
[Service]
MemoryHigh=7G
MemoryMax=8G
Environment=MEMORY_BUDGET_MB=6500
Environment=MIN_SESSION_KILL_MB=4000
Environment=MAX_CONCURRENT=2
```

These are deployment overrides, not universal defaults. Check `config.env` for
conflicting overrides. After installing the drop-in, reload systemd, restart the
service, and verify effective limits and the startup snapshot. Watch subtree RSS,
aggregate memory, host available memory and worker exits during real builds.

When fixing event feedback loops, stop the service first. Run all offline tests
against the exact deployed revision. Bot lease, status and state comments must be
ignored; unmarked human comments must remain eligible. Never generate external
PR comments just to test without authorization. Verify an existing delivery or a
new genuine event through intake, routing and response; distinguish heartbeat
recovery from a human-comment-triggered response.
