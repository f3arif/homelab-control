# Combined H3 backend qualification: R2 expired-token recovery + R3 Auto source ranking

**Status: TESTED / STAGED ONLY.** The production H3 catalog remains unchanged as of the final local verification on 2026-10-11 06:21 UTC.

## Byte-exact source lineage

| Version | SHA-256 |
| --- | --- |
| H3 original `stremio_catalog.py` | `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f` |
| R2 persisted historical-token recovery | `3dab113e23725a39401f8ba3c619b9eb0b6cd5eec47a0f677df2dc84404a74a5` |
| Combined R2+R3 candidate | `2b7a5b73392f21b99ee4b2234062b4d75c7118fd6f7fecc0d841f32691ae6572` |

The R3 incremental patch applies cleanly **on top of the R2 candidate** using `git -c core.autocrlf=false apply`. Its output was verified byte-for-byte against the combined candidate (not merely syntax or text normalized by Windows).

The pinned H3 stage directory is:

`C:\AFZ\Nuvio-Setup-20260923\onn-r2-r3-combined-20261011`

It contains the exact combined candidate, adapted non-destructive test runners, private HTTP fixture receipts, and final qualification JSON. The canonical R2 source/patch and rollback installer remain under `onn-expired-token-repair-20261011`.

## Combined acceptance

| Check group | Passed |
| --- | ---: |
| R2 history, TTL, release match, persistence and concurrency regressions | 23 |
| R3 provider/size/freshness rank and fallback regressions (live bridge metadata) | 43 |
| Real H3 bridge integration using synthetic expired tokens for two movies | 2 |
| R2 historical token HTTP fixture across a process restart | 13 |
| R3 Auto Mobile/Data Saver HTTP selection and provider fallback fixture | 10 |
| **Total** | **91 / 91** |

The private HTTP test servers were stopped. No user media was downloaded, account data reset, TV APK changed, or production catalog restarted.

The R3 HTTP test verifies that a stale Spider-Man Auto Saver request refreshes choices and returns the healthy Comet mock source, Mobile also picks Comet, and a simulated Comet outage allows the existing second-provider fallback to Debridio. It does not prove remote provider uptime on the real television; physical playback acceptance is still required after actual deployment.

## Release ordering and safeguards

The existing Windows Scheduled Task **AFZ Nuvio R2 Safe Idle Deploy** is still pinned to the **R2-only** candidate. It has strict no-active-media TCP and HLS/segment request guards, restarts only H3 catalog and is bounded to its original deadline `2026-10-11T13:10:22Z`. **Do not silently alter the task to use the combined candidate** without reconciling the hash-guarded installer and its rollback/acceptance checks.

After the task records R2 `DEPLOYED_AND_SMOKE_VERIFIED`, apply `r2-to-r3-incremental.patch` to a staging copy of that exact R2 source, verify the combined SHA above and rerun the 91 checks (especially against any newly modified source). During another true idle window, back up the R2 source, deploy R3 with catalog-only restart and automatic rollback; do not disrupt active sports or movie streams.

Alternatively, a single combined rollout from the original baseline would require a **new explicitly qualified** hash-pinned deployer and an independently checked rollback plan; it is *not* authorized by the existing R2 watcher or by these staging tests.

The earlier Spider-Man 404 token was already absent from the original cache, so R2 cannot retroactively recover that exact token. Refresh the Nuvio stream picker and choose a cached explicit Comet 1080p source for immediate playback.

## Remaining known limitations

- R2 addresses expired tokens only when historical metadata exists and a precisely matching replacement remains available.
- R3 improves Auto Mobile/Saver choices, but the live bridge or provider can still return 503.
- Range-request source pinning for the duration of an Auto playback session remains an independent follow-up; do not assume R3 fixes switching between releases mid-session.
- No production change until a receipt, SHA and post-deployment playback tests prove it.

Related: [Issue #265](https://github.com/f3arif/homelab-control/issues/265), [R2 draft PR #267](https://github.com/f3arif/homelab-control/pull/267), [R3 draft PR #268](https://github.com/f3arif/homelab-control/pull/268).


## 2026-10-11 afternoon — private real-provider HTTP canary (11/11 PASS)

The original R2 idle-watch deadline expired at 09:10 EDT without deployment (last successful watch run ~09:06 returned `WAITING_FOR_QUIET`). On H3 at ~14:49 EDT the scheduled task remained enabled but had no next run; it was explicitly **disabled** after confirming expiration. Production catalog still returned HTTP 200 with original SHA `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f`. Do not restart this expired watcher or claim deployment.

A new, isolated real-provider canary ran the **combined R2+R3 candidate** on H3 loopback-only port `127.0.0.1:18786`, with its own temporary state and *real* existing H3 Stremio bridge on `127.0.0.1:18768`. It used the existing health metrics and intentionally aged copied source rows to exercise the automatic fresh-source lookup. Only **HTTP HEAD** calls were sent to the `/auto-stream` media routes; no complete media files were downloaded. Known movie metadata/release permission was seeded **only in the temporary sidecar wrapper** to prevent unrelated Cinemeta date/caching behavior affecting the test.

**11/11 checks passed:** source hashes, private port availability, live bridge health, isolated manifest, two successful real-provider HEAD requests, two automatic source-cache refresh verifications, unchanged production SHA, and production manifest HTTP 200.

- Spider-Man `tt22084616`: TorBox/**Comet**, HTTP **200** in **7.16s**, refreshed to 80 source rows, 52 from Comet.
- Tenet `tt6723592`: TorBox/**Comet**, HTTP **200** in **6.14s**, refreshed to 3 source rows, 2 from Comet.

All source URLs and signed tokens were omitted from the report. The sidecar was stopped and private port 18786 was confirmed closed. Script `qualify_real_bridge_canary.py` and receipt `r2r3-real-provider-canary.json` were archived in draft PR #268. These checks establish actual provider HTTP response and source ranking from the combined candidate **without disturbing production**, but they do **not** prove 60s sustained playback on the original onn TV or that every provider is reliable.

The latest production release gates remain unchanged: the original H3 streaming service is active; R2 and combined R2+R3 are **staged only**; the expired R2 watcher is disabled; a controlled, guarded cutover or a private TV-specific canary addon is required for full end-to-end acceptance.
