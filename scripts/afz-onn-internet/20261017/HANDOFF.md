# AFZ Internet — ONN add-on without a client VPN

Resume key: **AFZ-ONN-INTERNET-20261017**.

AFZ Internet is a separate Stremio add-on for movies and series. It is installed on the identity-verified ONN 4K Streaming Box in **com.stremio.one 1.11.2**. The install screen changed from **Install** to **Uninstall**, with no VPN transport or tun0 present on the box. Select **AFZ Internet** in the source/add-on list while Tailscale is off.

## Current deployment

| Item | Value |
| --- | --- |
| Add-on ID | com.afzengineering.releasecatalog.internet |
| Public ingress | H3's existing HTTPS hostname, port 443, private token path |
| Gateway listener | H3 loopback 127.0.0.1:19088 |
| Upstream | Existing H3 AFZ core at 127.0.0.1:18774 |
| Program/config directory | C:/Users/Faiz/AppData/Local/AFZ/ONN-Internet-20261017 |
| Persistent task | AFZ ONN Internet Gateway |
| Startup | At boot and Faiz sign-in, S4U/Limited, one instance, bounded restart policy |
| Supported content | 16 movie/series catalogs, metadata, artwork and provider streams |
| Gateway SHA-256 | cd561c26587fa7c86689226b95c79189d93d9c132a71941b44a71ceeefa681dc |

The ONN uses ordinary public DNS and HTTPS. H3 provides server-side internet ingress and the existing AFZ backend. Provider redirects remain direct HTTPS video links. No chat session, Envy connection, or ZBook process is needed for this final runtime.

The original add-on remains installed. Live TV/sport catalogs and browser management/download actions belong to the original add-on; this transport advertises movie/series playback only. No APK, account credential, profile, phone setting or existing catalog source was replaced.

## Validation

- **30 focused tests pass on Linux and native Windows Python**: token checks, traversal/control-route rejection, safe metadata/URL rewriting, supported catalog filtering, redirects, GET/HEAD ranges, unavailable sources and CORS.
- Public-DNS/public-relay verification with validated TLS passed **10 checks**: manifest, catalog, metadata, artwork, source list, anonymous denial, control-route denial, video start range, seek range and HEAD.
- Seinfeld S3E11 returned valid video data for bytes 0–4095 and 1,048,576–1,052,671; full selected size remained 2,573,211,753 bytes.
- Physical ONN installation/manifest loading succeeded while no VPN transport was present. Rendered video/audio on the ONN was not observed by this checkpoint.
- All **19 previous H3 TCP mappings and 14 Web mappings** were preserved when the new protected ingress was added. The core catalog service was not restarted or patched.
- A preliminary ZBook deployment was retired after its public DNS did not become available in the bounded window. Its new Funnel mapping was removed, gateway disabled, and verification job stopped; its original six routes remain. Final production uses H3's existing public DNS.

## Continue from Git

Clone this branch and read this file first:

~~~bash
git clone --depth 1 --branch feat/afz-onn-internet-20261017 https://github.com/f3arif/homelab-control.git
cd homelab-control
git rev-parse HEAD
cat scripts/afz-onn-internet/20261017/HANDOFF.md
~~~

For an existing checkout, fetch the branch and inspect it in a separate worktree. Preserve unrelated local changes. Compare the live gateway hash and receipt before any source update.

## Recover the current installation

On H3, inspect the existing task and local receipt first. **Do not rerun install_h3.ps1 on this completed installation**; it intentionally refuses an existing task/configuration.

~~~powershell
$root=Join-Path $env:LOCALAPPDATA 'AFZ\ONN-Internet-20261017'
Get-ScheduledTask -TaskName 'AFZ ONN Internet Gateway'
Get-Content (Join-Path $root 'source-receipt.json')
Get-Content (Join-Path $root 'h3-rollout-receipt.json')
Get-FileHash (Join-Path $root 'gateway.py') -Algorithm SHA256
~~~

The private install/setup links are in installation-links-private.json in that directory. Read them only in an authorized operator session; their actual values are excluded from Git and the shared checkpoint.

Windows task stdout/stderr are redirected separately so ordinary native stderr does not terminate the PowerShell runner. No console needs to remain open.

For a reviewed source update, back up the current files, copy the candidate code/tests, run the tests, and use refresh_h3.ps1. It verifies the gateway process identity before restarting only this new task. Do not restart the AFZ core or Tailscale as a routine check.

## Fresh H3 installation only

Copy gateway.py, test_gateway.py and install_h3.ps1 into the program directory above. Run test_gateway.py using H3's native Python before the installer. The installer generates a random private token when no seed links exist, refuses an occupied listener or HTTPS ingress, registers the task, checks the local manifest and verifies prior mappings after publication.

The public gateway is limited to authenticated GET/HEAD/OPTIONS and validated AFZ routes. It excludes admin/control paths, credentials/cookies, private downstream URLs and unsupported actions. It bounds active upstream requests, total connections and idle client time.

## Rollback

rollback_h3.ps1 is a deliberate rollback action, not a diagnostic. It checks that the current port-443 mapping and scheduled task belong to this gateway, removes only this ingress, and stops/disables only this task. It retains configuration and every other service. Never run a global Serve/Funnel reset.

The CLI behavior is documented at https://tailscale.com/docs/reference/tailscale-cli/funnel.

## Evidence and next checks

- H3: C:/AFZ/Evidence/ONN-Internet-20261017 — identity, no-VPN state and sanitized UI summaries.
- H3 program directory — private XML captures, installation links, source receipt, task logs and rollout receipt.
- Envy: /home/coolyo/.local/share/afz-onn-internet-20261017 — deployment source and operator relay scripts.
- ZBook: /home/coolyo/.local/share/afz-onn-no-vpn-20261017 — public verification report and retired-trial receipt.

Raw URLs/tokens, account data, screenshots, browser storage, provider credentials and private logs are excluded from Git.

If the user reports a playback failure, collect the current failing source and player error while the ONN remains without a VPN. Distinguish a manifest/catalog problem from a media/decoder problem. Preserve the separate earlier expired-token recovery PR #271 and the user's other apps/downloads.
