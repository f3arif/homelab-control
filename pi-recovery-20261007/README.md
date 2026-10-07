# Pi recovery return — 2026-10-07

The Raspberry Pi returned after replacement of its USB SSD adapter. Its existing
recovery page had no supervisor and could exit while the Tailscale bind address
was unavailable. Separately, the running Docker watchdog used a two-second HP
health timeout, shorter than the healthy endpoint's observed response time.

## Changes

- `run.sh` preserves the existing reboot cron entry and single-instance flock,
  then starts `supervisor.py`. The supervisor retries a failed server with
  bounded backoff and forwards shutdown signals to its child.
- `patch_recovery.py` provides exact-anchor transformations of the private
  deployment files. The server's HP timeout becomes six seconds, the watchdog's
  direct health budget eight seconds, and recovery status/wake budgets ten
  seconds. The existing wake target, threshold, cooldown and grace period stay
  in force. An already reachable HP SSH endpoint short-circuits the wake guard.
- The retired Windows host is removed from recovery network probes and the
  recovery page. The status response retains a `windows` compatibility object
  explicitly marked retired. The patcher can remove the explicitly identified
  retired secondary origin from the Pi's nginx proxy.

Runtime addresses, MACs and private deployment logs are intentionally absent.
Fixtures use reserved documentation addresses. These scripts do not alter DNS
settings, public routing, SSH credentials, firmware or disk partitions.

## Verification

Run from this directory with Python 3 and `sh`/`wget` available:

```sh
python3 -m unittest -v test_recovery test_supervisor
sh -n run.sh
```

The tests exercise delayed health responses, suppression of unnecessary wake
packets, absence of retired-host probes, exact-anchor rejection, preservation
of the current nginx origin, startup retry, bounded backoff, and clean child
shutdown. They use local temporary services and do not contact deployment hosts.

## Deployment and rollback

Apply these repairs to the existing user-owned deployment, after checking each
original file's SHA-256 against the inspected version. Keep dated private copies
of original bytes, modes and a manifest. Transform the server and the **active
Docker watchdog bind source**, not the unused older user-service script. Compile
the staged Python and check shell syntax before replacing files. Preserve the
Tailscale-only bind address and the existing reboot cron entry.

Start the recovery wrapper and verify `/health` and `/api/status`. Restart only
the existing Docker watchdog and verify its mounted script hash and a HEALTHY
state. For the nginx edit, preserve the bind-mounted file inode, check
`nginx -t`, then reload and verify both the proxy page and health endpoint.
Roll back the private originals on any failed validation.

To undo the recovery repair, terminate the recorded supervisor PID, restore the
original server and wrapper with their original modes, restore the active
watchdog script and restart that container. Restore the nginx original in place,
validate, and reload. The original cron entry remains the startup mechanism.

The hardware return and resumed backup jobs were observed on the actual Pi.
Startup retry and signal behavior are tested without intentionally rebooting or
power-cycling a serving device.
