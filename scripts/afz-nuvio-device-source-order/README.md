# AFZ Nuvio — device-aware stream priorities (phone versus TV)

**Status: deployed as a limited, reversible Tailscale HTTPS path overlay on H3 on 2026-10-12.** Original H3 streaming catalog, playback links, live sports and Nuvio accounts remain unchanged.

## User-visible issue

On a OnePlus phone, the original Nuvio stream picker displayed **AFZ Play Best — 2160p / 15.9 GB** first for `Runway 34`, ahead of the **1080p / 3.3 GB** cached Data Saver choice, with "Auto-save" and "Last Auto Source" status also appearing near the top.

The AFZ backend specifically placed `AFZ Play Best` first in `auto_quality_streams`. Nuvio's `StreamAutoPlaySelector.orderAddonStreams` orders addon groups but preserves the sequence within an addon; changing metadata labels alone does not correct ordering. Source: upstream NuvioMedia/NuvioTV stream ViewModel and selector, inspected without changing the original APK.

## Live approach

The existing HTTPS addon `desktop-h3r6cqn.tailc9bb62.ts.net:8445` retains its original Tailscale Serve root route to `127.0.0.1:18774`. A new **only** `/stream/movie` path handler forwards to the lightweight source-list sorter on `127.0.0.1:18789`.

Serve automatically strips the `/stream/movie` prefix; the sorter accepts both the stripped and full movie listing path, fetches the existing H3 backend's JSON, and changes the **order and phone recommendation display label only**. It never rewrites any playback URL, replaces a media file, modifies production caches, edits an account or exposes a public Internet listener.

Device classification is derived from Tailscale peer hostnames (OnePlus, Pixel, iPhone, Samsung, etc. as phones; onn, Shield, Fire TV, Chromecast, etc. as TVs) and a small private local override file `device-policy.json`. Unknown peers get the exact original source list without reordering. Tailscale client IP is interpreted only when forwarded by the local Serve proxy; no unrestricted external user-header trust. Device IPs and user credentials **are not committed**.

### Verified Runway 34 priority

| Phone position | Source | Approximate size |
| --- | --- | --- |
| 1 | **AFZ Recommended for Phone** (Data Saver / TorBox-Comet 1080p) | **3.3 GB** |
| 2 | Cached explicit 1080p Comet | 3.3 GB |
| 3 | Cached explicit 1080p Comet | 5.0 GB |
| 4 | AFZ Auto Mobile | 6.0 GB |
| 5 | AFZ Auto 1080p | 6.0 GB |
| Later | Large 4K options (Play Best / Auto TV / Auto 4K) | ~15.9 GB |
| Last | Last Auto Source status and Auto-save controls | — |

On the **onn 4K TV**, `AFZ Play Best` at 2160p stays first; unrecognized devices also stay unchanged. All **16 source entries and all original source URLs** remain present, so user playback and fallback choices are not removed.

**Limitation:** This is a device-sensitive *source ordering* fix on the existing H3 tailnet HTTPS addon URL. It does not guarantee 3–5 GB versions for movies whose current source list has no small cached candidate; the separately qualified R3 backend refresh in [draft PR #268](https://github.com/f3arif/homelab-control/pull/268) is still staged, not production. Other hostnames and direct LAN-only addon routes will continue their current behavior until independently routed and tested.

## Tests and live checks

- **51/51** unit and H3-backed regressions passed across Runway 34, Tenet, Spider-Man and Insidious, including unknown-device passthrough, TV parity, original URL multiset preservation, controls at bottom, and manual smaller phone sources ahead of larger Auto Mobile.
- New sidecar SHA-256: `ed9af3890dec644974ce370eece1dd597b329aae3821844ec68771f55276471d`.
- Original H3 catalog SHA-256: `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f`, unmodified.
- Tailscale Serve test paths on separate temporary ports were exercised with valid TLS and then removed; existing root mappings were verified unchanged.
- Production `/manifest.json` still returns addon ID `com.afzengineering.releasecatalog` HTTP 200; live `/stream/movie/tt11460992.json` returns HTTP 200 and the source-order policy header.
- H3's known OnePlus and Pixel peer IPs in private local tests receive phone ranking; the known onn TV IP receives the unchanged TV ranking. ZBook/unknown peer received original data over the new HTTPS proxy. **Physical OnePlus Nuvio UI refresh is the remaining visual acceptance step**.

## Durable operations

H3 folder: `C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012`.

- `device_source_order.py`: read-only response transformer for stream listing requests.
- `generate_device_policy.py`: **dry run by default**; use `--apply` only on a new host when `device-policy.json` does not yet exist. Prints counts, never peer IP addresses.
- `device-policy.example.json`: schema only. The real H3 policy remains on H3, excluded from GitHub.
- `test_device_order.py`: 51 regression tests; needs access to the original H3 catalog and local device policy.
- `Start-Device-Order-Sidecar.ps1 -Apply`: launches loopback-only port 18789 with pinned original production source SHA and no overlapping processes.
- `Deploy-Device-Source-Order.ps1 -Apply`: maps **only** HTTPS root `/stream/movie` to the sorter. Verifies phone and TV ranking, unchanged root, and all unrelated Serve mappings; rolls back the path on error.
- `Rollback-Device-Source-Order.ps1 -Apply`: removes **only** that path handler, returning every source listing to the original H3 backend immediately. Does not reset Serve or modify playback routes.
- `Guard-Device-Source-Order.ps1`: fail-safe health worker. H3 task **AFZ Nuvio Device Sort Guard**, runs as SYSTEM every **two minutes**, verifies the known sorter process and source-list behavior, attempts to restart a dead sidecar, and if recovery fails removes only its Serve path. It never stops the production catalog, touches media, or changes account data. It does not silently re-add a deliberately rolled-back path.

The automatic health task returned **HEALTHY**, Task Scheduler last result 0, and H3 catalog HTTP 200. Its status file `device-order-guard-status.json` and actual Serve snapshot are retained on H3.

**Do not run** `tailscale serve reset`: it removes unrelated mappings, including existing apps and live sports.

## Next acceptance

On the OnePlus, keep Tailscale connected with DNS working. In the original Nuvio app, reopen `Runway 34` and tap Refresh. Its first row should read **AFZ Recommended for Phone**, 1080p / 3.3 GB. If an old cached stream list remains, refresh the addon and restart Nuvio without clearing app data. The onn 4K box should still show its usual 4K-first behavior. Confirm no source count loss and no interrupted playback.

Related: [Issue #265](https://github.com/f3arif/homelab-control/issues/265), [R2 draft PR #267](https://github.com/f3arif/homelab-control/pull/267), [R3 draft PR #268](https://github.com/f3arif/homelab-control/pull/268).
