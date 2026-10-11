# AFZ Nuvio onn 4K — R3 healthier Auto Mobile / Data Saver selection

**Status:** STAGED / TESTED ONLY — not merged, not deployed.

Tracked under [Issue #265](https://github.com/f3arif/homelab-control/issues/265). This is a separate change from the expired-token history repair in draft [PR #267](https://github.com/f3arif/homelab-control/pull/267). **Do not overwrite R2 with this independent baseline patch.** If R2 deploys, reconcile/rebase the patches against the new H3 source and retest rather than applying R3 directly.

## Problem reproduced

The H3 failover catalog often serves cached remote source metadata long after its source discovery TTL. In the sampled Spider-Man source list, the stale catalog offered 2–5 GiB choices from Debridio/Torrentio but **no Comet** sources, while a fresh 2.2s bridge lookup returned **16 cached 1080p Comet sources between 2–5 GiB**.

Live provider-health evidence: TorBox / Comet had **521/534** successful recorded checks and no consecutive failure streak; TorBox / Debridio had **133/179** successful checks with eight consecutive failures at last probe. The old `_auto_profile_rank` sorted Spider-Man Mobile and Saver to a 3.7 GiB Debridio release, despite smaller healthier Comet choices being available after refresh. The onn 4K physical test saw that Debridio source time out repeatedly before HTTP 503, whereas an explicit 4.1 GiB Comet source played for approximately 50s with around 50s buffered.

## R3 solution

- On actual `/auto-stream/{vid}/mobile` and `/auto-stream/{vid}/saver` playback requests, force a bounded H3 bridge source refresh only when the catalog is older than 300s. This does not turn stream-picker rendering into a synchronous network request.
- Prefer cached sources with no recent serious provider failures, targeting 2–5 GiB first for Saver and 2–8 GiB first for Mobile, then progressively relaxing the size constraint. If small or healthy sources are unavailable, keep original alternatives rather than returning an empty list.
- Retain the entire original ranked pool after the preferred tier. Existing two-provider fallback continues to work when a Comet attempt fails.
- Recent unhealthy provider signals: an active cooldown, or at least three consecutive failures (or fewer than 60% successes across 10+ checks) with a failure during the past 6 hours. This is a temporary preference, **not** a permanent block.
- `Play Best`, `Auto TV`, all explicit manual source URLs, movie IDs, account data and media storage remain unchanged. No device-specific APK change.

## Verification

- H3 production baseline SHA-256: `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f`
- R3 staged candidate SHA-256: `2e5b2c55967b31cd8eb149c9291ca12b5246d34ce80bd4cc276f21ea1654f013`
- Python syntax AST parse: **PASS**
- Isolated R3 regressions: **43/43 PASS**, using fresh, real H3 bridge source metadata for Spider-Man, Tenet and Insidious (without fetching media).
- Local HTTP fixture: **10/10 PASS**. On private H3 loopback ports with a fake bridge, actual Auto Saver and Mobile HEAD/GET endpoints returned the healthy cached Comet selection, and the Saver endpoint fell back to Debridio after a simulated Comet probe failure. Both private servers shut down.
- Patch check and application with `git -c core.autocrlf=false apply`: **PASS**, output byte-for-byte identical to candidate.
- H3 production catalog verified unchanged while testing, original Nuvio `com.nuvio.tv` remains installed with AFZ sign-in intact.

## Source and tests

- `auto-source-ranking-r3.patch` — R3 diff against the exact original H3 production baseline. Use `git -c core.autocrlf=false apply` to avoid CRLF conversion.
- `build_r3.py` — deterministic candidate construction with SHA baseline guard.
- `test_r3.py` — 43 isolated ranking, freshness, fail-open-fallback and compatibility assertions.
- `test_r3_http.py` — 10 isolated localhost-only HTTP route and provider-fallback checks.
- H3 local staged directory: `C:\AFZ\Nuvio-Setup-20260923\onn-auto-source-r3-20261011`.

## Deployment safety

R2 is still awaiting a safe idle window under its separate guarded Task Scheduler workflow. This R3 change must not be automatically deployed by that watcher. First integrate the two patches on a new baseline, verify byte-exact patch reconstruction, rerun both suites and the private HTTP sidecars, and only then use a guarded idle-service deployment and rollback. Never restart a live sports HLS/segment stream to make a deployment fit the window.

R3 improves source-selection resilience but cannot guarantee provider uptime, 60s video playback, or stable seek behavior. A future improvement should pin the chosen Auto release for a playback session so Range requests do not silently switch between files when source lists refresh.
