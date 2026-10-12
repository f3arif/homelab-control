# AFZ Nuvio — device-based Play Best V2 (2026-10-12)

**Status: LIVE on H3's private Tailscale movie-list path; physical OnePlus Nuvio screen still awaiting user refresh/confirmation.** V2 extends V1; the original media-serving H3 catalog and TV APK have not been rebuilt or restarted.

## Why V2 was needed

The original AFZ addon ranked a **15.9 GB 2160p** Runway 34 release as `AFZ Play Best` on phones. V1 (the prior routing overlay on 127.0.0.1:18789) added a separate `AFZ Recommended for Phone` entry before the existing `AFZ Play Best`, but left the latter pointing to the 4K file. Nuvio may give the `AFZ Play Best` label special prominence, so V2 changes the *existing* Play Best entry's recommendation on phones rather than relying only on list order.

For OnePlus/Pixel phones, V2 reuses the best cached, appropriately sized **1080p** Auto Saver / Mobile choice to populate the top `AFZ Play Best` label. Its media URL points at the existing production Auto route with a harmless `afz_phone_best=1` query marker to prevent deduplication; the original server ignores that extra query parameter. It then prioritizes small cached manual 1080p choices and keeps all other options, including 4K. On the onn 4K TV and unknown desktops, V2 returns the original JSON ordering unchanged.

## Runway 34 verified output

| Device role | First item | Displayed details |
| --- | --- | --- |
| OnePlus 13R / Pixel phones | AFZ Play Best | **1080p WEB-DL, 3.3 GB, TorBox/Comet, cached** |
| onn 4K TV | AFZ Play Best | **2160p WEB-DL, 15.9 GB**, original TV preference |
| Unclassified | Original first item | No source-list modification |

For other tested titles, the phone's first item used 1080p: Spider-Man 3.6 GB, Insidious 3.6 GB, and Tenet 7.8 GB. This is a *preference*, not a promise that every title has a 3–5 GB compatible source or that every TorBox link is reachable. The separately staged R2/R3 source-recovery and provider-health changes remain outside production.

## Live architecture

- Existing H3 private HTTPS addon: `https://desktop-h3r6cqn.tailc9bb62.ts.net:8445`.
- Original Tailscale Serve root `/`: **unchanged**, proxies to H3 catalog `127.0.0.1:18774`.
- Only `/stream/movie` (movie source-list JSON): proxies to V2 on `127.0.0.1:18792`. Tailscale Serve strips the prefix; V2 understands both original and stripped paths.
- V1 `device_source_order.py` on port **18789** is still available as a running, known-good rollback target. The original V1 sidecar code was not overwritten.
- Movie/media playback, HLS sports, `/auto-stream`, `/external-stream`, catalog, download controls, account sync and other service paths remain routed to the original server.
- Device class comes from H3's private `device-policy.json` and cached Tailscale peer names. That policy contains device-specific tailnet addresses and **must not be committed**.
- The new V2 service adds no public listener and no Funnel. Existing Tailscale Serve mappings were checked before and after the path-only update.

## Test and rollout evidence

- Original H3 catalog SHA-256 `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f` remains unchanged.
- V1 sorter SHA-256 `ed9af3890dec644974ce370eece1dd597b329aae3821844ec68771f55276471d` preserved for fallback.
- Live V2 sorter SHA-256 `1c144432e242c42027eb00dc8841aeb9c5f3930863ea434de326829e447ac3be`.
- The original V1 routing baseline existed on H3 before the V2 work. A private test proved existing Serve path handlers can switch targets atomically without changing the root.
- **142/142 initial V2 HTTP/device checks passed** and **187/187 reproducible acceptance checks passed** across Runway 34, Spider-Man, Tenet and Insidious. These verify simulated OnePlus/Pixel versus onn/desktop classification, source counts, the top phone Play Best 1080p label, preservation of other playback URLs, explicit 4K alternatives and the original H3 media source hash.
- The actual old Auto Saver endpoint accepted the alias query parameter and returned successful HEAD; this is a connectivity check, not a full movie playback test.
- A real OnePlus-screen verification after refreshing Nuvio is **still required**.

## Automatic health and rollback

Task Scheduler on H3:

- `AFZ Nuvio Device Sort V2 Guard`: **enabled**, runs as SYSTEM every 2 minutes, checks V2 source SHA and original catalog SHA, health endpoint, phone Play Best 1080p and TV Play Best 2160p. It restarts *only* V2 if needed.
- If V2 remains unhealthy, it restores the Tailscale movie-list prefix to the original V1 sorter, reenables the V1 task, and disables itself. If both are down, it removes only the prefix, returning to the original H3 catalog. It never resets all Serve routes.
- `AFZ Nuvio Device Sort Guard` (V1): **disabled while V2 is healthy**, retained for rollback.
- `Rollback-Device-Order-v2.ps1` is an explicit hash-guarded manual fallback. Dry run is verified. To revert V2 without affecting media services, run it with `-Apply` on H3.
- Exact pre-cutover Tailscale Serve configuration, V1 scheduled-task XML, V2 runtime receipt, backups, and private device policy remain locally under `C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012`.

**Recovery key:** `AFZ-NUVIO-DEVICE-PLAYBEST-V2-20261012`

Next acceptance: On OnePlus with Tailscale connected/DNS enabled, open Nuvio → Runway 34 → Refresh sources. Confirm the first AFZ Play Best item displays ~1080p / 3.3 GB; if the app sorts by its own rules, capture a screenshot and inspect its sorting logic separately. Do not clear Nuvio data or reinstall the signed-in app.

Related: [Original issue #265](https://github.com/f3arif/homelab-control/issues/265), [V1/V2 draft PR #269](https://github.com/f3arif/homelab-control/pull/269), [R2 PR #267](https://github.com/f3arif/homelab-control/pull/267), [R3 PR #268](https://github.com/f3arif/homelab-control/pull/268).
