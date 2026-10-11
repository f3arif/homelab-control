# Nuvio add-on setup continuation — 11 October 2026 UTC

Resume key: AFZ-NUVIO-ADDON-SETUP-ACCESS-20261011

## Verified

- Existing Pixel 8 R32 acceptance remains complete: mobile-first ordering, bounded streaming, pause/resume, full download, local playback and airplane-mode playback. Do not repeat the 2 GB transfer or isolation test.
- Desktop Commander tools became available after the account change. The new connection reports its full monthly allowance.
- All three devices on that account were offline on the live refresh. H3 and HP Envy were last seen roughly 20 days earlier; these entries are stale, not current execution sessions.
- Read-only GitHub Actions source probe ran: https://github.com/f3arif/homelab-control/actions/runs/38109230947 .
- Tailscale JWT exchange returned HTTP 403 Unauthorized. The source-inspection step was skipped. No host command, source mutation, build, install or phone operation occurred.

## Pending work

1. Pair an online H3 Desktop Commander agent with the same account as the ChatGPT connection. Refresh device identity before executing commands.
2. Read exact R32 source at C:\AFZ\Nuvio-Setup-20260923\R32-phone-first-source; verify expected commit 1922ff0108e8b99c1f0be74c0592d251c5fb63a9 and worktree state.
3. Fix case-insensitive HTTPS/HTTP/Stremio scheme handling, preserving path and query case.
4. Fix duplicate in-memory add-on installs when concurrent requests pass the initial duplicate check before manifest fetch finishes.
5. Add meaningful normalization and concurrent-install regression tests, build in an isolated copy, and physically verify on Pixel 8 after rechecking model/serial and the current wireless-debugging endpoint.

## Boundaries

No setup fix has been implemented or validated. Pinned upstream AddonRepository was inspected, but its equality with the live R32 file has not been verified.
The probe workflow uses the existing HP-to-H3 SSH path and existing repository Tailscale credentials. Do not retry the failed authorization by disguising branch/workflow identity or changing trust policy.
The branch is separate from R32 draft PR #263 and backend PR #264; neither existing branch or pull request changed.
No pairing code, protected add-on URL, credentials, or raw phone screenshots are recorded here.
