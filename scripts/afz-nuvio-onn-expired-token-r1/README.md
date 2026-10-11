# AFZ Nuvio onn 4K — expired remote stream token recovery (R1)

Tracked under [Issue #265](https://github.com/f3arif/homelab-control/issues/265). This is a **backend-only** guarded patch to the H3 fallback `stremio_catalog.py`. It does **not** change the original TV `com.nuvio.tv` APK, install AFZ Preview, reset accounts, or change media storage.

## Verified 2026-10-11

- Original source SHA256: `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f`
- Staged candidate source SHA256: `dbe5f5be8d6b8b676f4a5cdfe123441d65f4bfc7fcf3892d4b6514b1122f469f`
- `ast.parse`: PASS
- Eleven isolated regression cases: PASS
- Staged live-bridge integration: two stale persisted tokens (Tenet and Insidious) recovered to newly resolved URLs for the **same release**; both PASS
- Direct pre-fix H3 HEAD tests for four cached old tokens: HTTP 404. Bridge error: `External stream token expired or not found`.
- H3 persisted source cache: 243 titles; sampled expired entries were approximately six hours old. Desktop Stremio bridge token registry has a 30-minute TTL and is in memory only.

## Behavior

The existing `/external-stream/{vid}/{token}` path first tries to resolve the selected token normally. If that fails, it looks up the old token in the persisted **same-title** source cache; performs one bounded source rediscovery; and uses a newly issued token only when **provider, source, resolution, size, and normalized release filename** match exactly. Unknown tokens and a different release continue to return 404. There is no arbitrary source substitution or media download.

When a token is no longer present in the persisted catalog, Nuvio must refresh its stream list. Provider-side 404 after a successful redirect is a separate issue and is not addressed by this patch.

## Staged on H3

`C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011`

This folder contains the original, candidate, exact patch, regression script, integration test, and staging receipt. Source worktree itself is not a Git repository; this GitHub branch stores the canonical diff and test.

## Safe deployment and rollback

Require live source SHA to equal the original SHA above; verify no active connected media sessions; back up the original byte-for-byte; install the candidate atomically; restart **only** the existing H3 catalog service on 127.0.0.1:18774, not the entire machine or Tailscale. Accept only if the manifest and catalog answer HTTP 200 and old cached-token HEAD changes from 404 to successful resolution. On any failure restore the original source and restart the same service; verify health again. Do not modify H3 origin files to match this patch if their hashes differ without reconciling them.

Avoid printing or committing private source URLs, token values, bridge credentials, headers, or entire playback records.

## Later device acceptance

Reauthorize Android debugging on onn box if requested. Test two **non-AFZ-Local** movies for 60 seconds each, including the original failing title, and verify no 404 or repeated rebuffer. Roll out separately from any TV UI / APK change. 
