# AFZ Nuvio — private onn 4K TV R2+R3 preview

**Status:** H3 preview running over Tailscale Serve; **not installed in Nuvio's signed-in AFZ profile yet**, and **not deployed to the production AFZ addon**.

## Preview address

`https://desktop-h3r6cqn.tailc9bb62.ts.net:18886/manifest.json`

Addon identity is `com.afzengineering.nuvio.tvpreview.r2r3` (display name **AFZ TV Preview R2+R3**), deliberately different from the production `com.afzengineering.releasecatalog`. The manifest advertises **only movie stream resources**, no catalogs, TV, series, sports, downloads, delete/control endpoints or library maintenance.

The preview serves source choices only for the three test movies: `tt6723592` (Tenet), `tt32393988` (Insidious: Out of the Further), and `tt22084616` (Spider-Man: Brand New Day). Each stream list includes Auto 1080p, Auto Mobile, and up to four small, cached, manually selectable releases. All URLs point back to the private preview port so the combined R2+R3 resolver/selection code is exercised. It does **not** replace or write production addon files.

## Verified

- Production H3 source SHA256: `d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f` (unchanged); live addon manifest HTTP 200.
- Private R2+R3 source SHA256: `2b7a5b73392f21b99ee4b2234062b4d75c7118fd6f7fecc0d841f32691ae6572`, verified against the staged 91-check qualifying candidate.
- Local H3 listener: `127.0.0.1:18786` only.
- Tailscale Serve: **HTTPS on tailnet-only port 18886** forwards only to that listener. Serve mapping saved before change; all eleven earlier HTTPS/HTTP Serve routes checked unchanged. **No Funnel/public exposure**.
- H3 and ZBook requested the preview manifest/stream endpoint over HTTPS and received HTTP 200 with TLS verification result 0. Catalog, series and unrelated movie/control endpoints return 404.
- Private preview provided six Tenet streams, including small Comet 1080p candidates. Its actual Auto Saver `HEAD /auto-stream/tt6723592/saver` returned HTTP **200** and `X-AFZ-Auto-Source: Comet`.
- The onn box has Tailscale connected on `tun1`, tailnet IP `100.116.144.59`; routing to H3 tailnet IP `100.106.186.118` and ping both succeeded.
- Original Nuvio `com.nuvio.tv` still signed into AFZ account. At inspection it showed **two installed addons**, and no preview install was submitted.
- Start and Stop PowerShell scripts both passed syntax checks; the Stop script ran a no-change dry-run and verified ownership of the new 18886 Serve route and private listener before allowing any cleanup.

## Why the TV addon has not been installed automatically

Nuvio's Settings → Content & Discovery → Addons has an **Install addon** URL field. The app's Account page indicates addon changes are synchronized at the signed-in profile/account level (and may propagate to other signed-in devices). To keep this a **TV-only** trial, adding it to the AFZ profile without confirming sync scope was deliberately held. Installing this addon does not require reinstalling Nuvio, clearing cache, signing out or replacing the existing AFZ addon, but may add an addon to the synced account.

The remaining TV acceptance is: choose how to isolate the addon/profile; install the separate preview manifest; then test two nonlocal movie streams for at least 60 seconds while monitoring playback logs and confirming the source route is the preview, not the production addon.

## Host controls and rollback

H3 staging folder: `C:\AFZ\Nuvio-Setup-20260923\onn-tv-private-preview-20261011`.

- `preview_app.py` — stream-only restricted FastAPI wrapper; reuses just the staged combined backend's read-only movie streaming endpoints.
- `Start-Nuvio-TV-Preview.ps1 -Apply` — hash-gated isolated server launch. Staged backend and isolated state live in this folder; no changes to H3 catalog process or media storage. Already run successfully; it is **not idempotent** if the prior process receipt still exists.
- `Stop-Nuvio-TV-Preview.ps1` — no-change preflight check of only the preview mapping and expected process.
- `Stop-Nuvio-TV-Preview.ps1 -Apply` — remove **only** the 18886 Serve route and stop the verified localhost preview listener. Preserve all other Tailscale Serve mappings and original catalog process.
- The original Serve snapshot is private on H3 as `tailscale-serve.before.json`. Do not use `tailscale serve reset` because that would remove unrelated live services.
- Original preview process receipt and current state are local: `preview-process.json`; no provider credentials or signed streaming links are committed to GitHub.

**Operational limitation:** This is currently a separately launched preview process, not an automatic restart service. It may need explicit recovery after an H3 reboot. Tailscale Serve configuration itself may persist while the backend is stopped.

Related checkpoints: [PR #267 (R2)](https://github.com/f3arif/homelab-control/pull/267), [PR #268 (R3 and combined)](https://github.com/f3arif/homelab-control/pull/268), [Issue #265](https://github.com/f3arif/homelab-control/issues/265). Production R2/R3 deployment remains held while H3 serves active catalog/live sports traffic.
