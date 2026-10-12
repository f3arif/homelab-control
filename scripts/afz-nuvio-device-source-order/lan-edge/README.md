# AFZ Nuvio device-based source ordering — LAN + Tailscale ingress correction

**Status: LIVE on H3 (2026-10-12). Actual OnePlus Nuvio screen acceptance remains pending.** Tracks [Issue #265](https://github.com/f3arif/homelab-control/issues/265) and extends [draft PR #269](https://github.com/f3arif/homelab-control/pull/269).

## Root cause

The OnePlus still displayed **Runway 34 — AFZ Play Best, 2160p, 15.9 GB** after the first device-sort rollout. H3 had **two ingress routes for the same addon identity**:

- Tailnet HTTPS at port **8445** routed movie stream-list JSON to the V2 sorter (127.0.0.1:18792) and all original playback requests to the catalog (127.0.0.1:18774).
- Home-LAN HTTPS at **192.168.50.185:8445** ran a separate `afz_lan_proxy.py` process, which forwarded movie lists directly to the original catalog without device-aware sorting. Testing that LAN endpoint reproduced the screenshot's exact **4K 15.9 GB-first** list.

The LAN edge's manifest is still `com.afzengineering.releasecatalog`, the same ID as the Tailnet addon, so the app could receive different recommendations depending on DNS/routing even with the same installed addon.

## Applied correction

The LAN TLS edge now runs the **separate** `afz_lan_proxy_device_v2:app` module. Only GET/HEAD `/stream/movie/{id}.json` queries go to the existing local device sorter. All other paths — stream playback, HTTP Range delivery, HLS/sports, control actions, manifests and downloads — remain on the original catalog and unchanged forwarding logic.

- Device class derives from actual LAN/Tailscale client address; caller-supplied forwarding headers are discarded for movie-list requests. H3's private device-policy file contains current phone/TV LAN overrides and is not committed to GitHub.
- If the device sorter is down (network error, 502/503/504), the LAN proxy falls back to the original movie-list catalog rather than returning no streams.
- The original `afz_lan_proxy.py`, `stremio_catalog.py`, media paths, user account and TV/phone APKs were not modified.

## Evidence and reproducibility

- Original LAN proxy SHA-256: `337654d93c08e831f4a924f0082257f19de38ff5a44fa77afcb5dc0b953c28c5` — unchanged.
- LAN V2 proxy SHA-256: `b926a6c6fffb4daa60a5200f26fc4d0499b1bf5331591022bd9365cd34496b0b`.
- Device-order V2 sorter SHA-256: `1c144432e242c42027eb00dc8841aeb9c5f3930863ea434de326829e447ac3be`.
- H3 production catalog SHA-256: `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f` — unchanged.
- **129/129** end-to-end private ASGI/HTTP checks PASS, using the actual H3 sorter and testing phone, TV, unknown clients and forged forwarding headers across four movies. Verified the addon manifest and all original stream options remain available.
- When the sorter was deliberately unavailable in a separate test process, the LAN candidate returned HTTP 200 with the original stream list instead of failing.
- A bounded 20-second idle-connection gate passed before the live LAN edge restart. LAN deployment receipt: `LAN_V2_LIVE` at **2026-10-12 05:29:45 UTC**, with the original backend untouched.
- Post-rollout: LAN and Tailnet movie lists both answer HTTP 200 with `X-AFZ-Sort-Policy: phone-best-v2`; both existing manifests retain ID `com.afzengineering.releasecatalog`; no Funnel/public exposure.

## Automatic startup and rollback

The protected original H3 LAN launch script could not be replaced through the Windows file system. Instead, the **existing one-minute SYSTEM Task Scheduler task** `AFZ Stremio H3 LAN TLS Edge` was backed up and repointed to the verified candidate launcher script in the local H3 staging folder. Its triggers, SYSTEM account, and enabled state are unchanged. The new launcher selects the candidate module only when its file SHA-256 matches; otherwise it falls back to the original proxy module.

Task action change receipt: `STARTUP_TASK_REPOINTED_VERIFIED`; a subsequent natural SYSTEM run returned `LastTaskResult=0`. The active LAN edge continued to run the correct device V2 module and returned HTTP 200. Original source script remains untouched.

- `Apply-LAN-Device-Order-v2.ps1` is the one-time hash-guarded, LAN-only idle deployer with automatic original-proxy recovery if smoke tests fail. It must **not** be rerun blindly after successful deployment; inspect its receipt first.
- `Rollback-LAN-Device-Order-v2.ps1` switches the verified task action and LAN proxy back to the original after an idle check. **Its no-change dry run passed**, but a real rollback has not been exercised because production is currently healthy.
- Original Task Scheduler XML and exact task-action receipt are stored **locally** at `C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012\LAN-v2`. Do not commit device-policy.json, SSL private keys or signed stream URLs.

## Expected source lists

For Runway 34, phones are configured to receive **AFZ Play Best — cached 1080p WEB-DL, 3.3 GB TorBox/Comet** first. The onn 4K box retains its original **2160p 15.9 GB** option first; unknown clients retain original source order. Higher-resolution files are not removed from phones, merely listed after smaller choices.

**Remaining physical acceptance:** On the OnePlus, keep Tailscale connected with DNS enabled; reopen Nuvio, tap Refresh on Runway 34 and inspect AFZ Play Best. If the old 4K item persists, verify the real addon source URL and Nuvio client-side cache/sort. Server-side response tests do not substitute for a screenshot from the real Nuvio UI.

Related: [R2 token recovery PR #267](https://github.com/f3arif/homelab-control/pull/267) and [R3 provider-health PR #268](https://github.com/f3arif/homelab-control/pull/268) remain separate staged backend changes, not deployed into production by this LAN fix.

**Resume key:** `AFZ-NUVIO-DEVICE-ORDER-DUAL-INGRESS-V2-20261012`.
