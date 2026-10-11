# R2 — bounded persisted history for expired Nuvio source tokens

This extends the original R1 patch, and the **R2 patch includes the full diff from the exact unmodified H3 production baseline**, not an incremental patch on an unrelated version.

## Verified H3 evidence

- Baseline source SHA-256: `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f`
- Staged R2 source SHA-256: `3dab113e23725a39401f8ba3c619b9eb0b6cd5eec47a0f677df2dc84404a74a5`
- Production source was unchanged when tests ran.
- Python AST syntax check: **PASS**
- Isolated R2 tests: **23/23 PASS**. Checks current token, stale token, old record absent from current cache but present in historical cache, JSON restart persistence, no URL retained in history, exact release match, no cross-title/provider/source/size/resolution substitution, unknown tokens, 72-hour expiry, malformed historical metadata, per-title/global memory limits, concurrent-safe persistence and no stale writer temp files, provider outage, and unmodified baseline.
- Real H3 bridge staged integration: **2/2 PASS** for `tt6723592` (Tenet) and `tt22084616` (Spider-Man). Each uses a **synthetic expired token with matching release metadata only in the historical map**, absent from the current rows; the candidate refreshed sources and resolved a fresh real bridge URL. No signed media URLs were logged or persisted.

## Scope / behavior

- Old source entries are archived **before** a successful catalog refresh replaces the current movie's source list.
- Historical entries are keyed to the original title ID and opaque source token. They retain **only** a limited subset of metadata required for safe release matching: provider, source, resolution, size, name/title/filename and token. Never store signed source URL, HTTP authorization header, or provider credentials in historical records.
- Retention: **72 hours**, at most **140 tokens per title** and **8,000 across titles**; expired and invalid records pruned. The history is part of the existing persisted `external-source-cache.json`, so restarts need no new service or database. The cache snapshot is serialized with a dedicated lock and writer-specific temporary file to avoid concurrent refresh writers clobbering the history.
- When `/external-stream/{vid}/{token}` cannot resolve directly, retrieve the exact old release identity from current rows or the bounded history, perform one refresh, and resolve **only an exact match**. Unknown/mismatched tokens still return HTTP 404.
- Existing series handling is unchanged, as are `/auto-stream`, TorBox account credentials, and media paths.
- Exact user screenshot token already absent before deployment cannot be recovered. Refresh Nuvio source picker and select a fresh explicit working 1080p Comet source.
- Provider-side HTTP 503 (Debridio intermittent) is **separate**, not fixed by this patch.

## Files

- `expired-token-history-r2.patch` — canonical guarded R2 full patch against baseline SHA above.
- `test_r2.py` — isolated regression suite; no external network or modification of production service.
- `integration_r2.py` — H3 live-bridge test using synthetic expired tokens; connects to bridge but does not write to production, download media, or expose secret URLs.
- H3 local staging is under `C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011`; includes full `stremio_catalog.r2.candidate.py`, original byte-for-byte backup, staging receipts, and tests.
- R1 prototype and patch retained as historical checkpoint; R2 supersedes for deployment.

## Deploy / rollback gate

Only deploy when live file SHA and candidate SHA match, no active stream clients are connected, verified backup exists, and the service's startup/health checks are ready. Back up the existing catalog file; atomic replace, restart only catalog process `127.0.0.1:18774` through the known H3 launcher, then verify manifest HTTP 200 and multiple stale-token HEAD calls. Roll back original SHA immediately on failure and verify health. Do **not** restart the H3 machine, Tailscale, Nuvio APK, or other media services.

## Physical acceptance

Repeat **60 seconds of uninterrupted non-AFZ-Local movie playback** on the onn 4K box using the original Nuvio package `com.nuvio.tv`, preserving AFZ account and watch history; prefer smaller cached TorBox/Comet sources. Any persistent Debridio timeout/503 requires a separate provider-aware routing investigation.

Tracked in [Issue #265](https://github.com/f3arif/homelab-control/issues/265) and Draft PR #267.
