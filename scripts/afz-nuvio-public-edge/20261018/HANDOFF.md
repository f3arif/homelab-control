# Restore AFZ Nuvio's original public edge after HTTP 502

The original protected AFZ address returned HTTP 502 for both manifest and episode sources because no process listened on loopback 18773. The core on 18774 remained healthy and returned 12 Seinfeld S3E11 sources. The separate AFZ Internet gateway on 443 also remained healthy. The old AFZ Stremio H3 Failover task was disabled, so it did not restore the original proxy.

## Deployed repair

On 18 October 2026 UTC, restored the existing afz_public_proxy module through a new dedicated Windows task, **AFZ Nuvio Public Edge**. It uses the existing transport token from the existing private state file and the original port-10000 address. No client reconfiguration is required.

- Native Python/uvicorn binds **127.0.0.1:18773**, forwarding to the existing **127.0.0.1:18774** core.
- Task starts at machine boot and Faiz sign-in, runs as S4U / Limited, allows one instance and three one-minute restart attempts, and has no normal runtime limit.
- The runner waits for its child. Unexpected clean child exit also returns failure so the scheduler can retry. A surviving valid proxy child is monitored rather than duplicated; an unrelated listener is refused.
- Existing AFZ proxy source, main core, source bridge, provider collection, tokens, disabled legacy tasks and the complete Tailscale Serve/Funnel configuration were preserved.
- No APK, account, phone, ONN, VPN/DNS or accepted-download change was made.

Program directory:
**C:/Users/Faiz/AppData/Local/AFZ/Nuvio-Public-Edge-20261018**

Evidence:
**C:/AFZ/Evidence/Nuvio-502-20261018**

Envy operator copy:
**/home/coolyo/.local/share/afz-nuvio-502-20261018**

Existing proxy source hash at deployment:
**a5f66368f5713718ae87d88e2e2780d98aeb9aba126148dc155259e004d54ebd**

The runtime is on H3 and does not depend on this chat, Envy, Commander or an interactive shell remaining connected. The precise reason the old process exited, and who disabled its historical startup task, were not established.

## Validation

All three PowerShell files passed the native Windows parser. Existing native Python imports for uvicorn, FastAPI and requests passed. The installer accepted the existing original Funnel mapping without rewriting it and verified the proxy source hash and complete Serve configuration remained unchanged.

After restoration, original AFZ manifest and sources returned **200**, with **19 catalogs / 12 sources**; separate AFZ Internet still returned **200 / 11 sources**.

Nine checks through **public DNS, a public relay address and validated TLS** passed: original manifest, anonymous denial (404), movie catalog, series metadata, artwork, episode sources, media start, seek and HEAD. Seinfeld S3E11 media checks returned exact **206** ranges **0–4095** and **1,048,576–1,052,671**, 4,096 bytes each, total **2,573,211,753 bytes**; start bytes had valid Matroska magic. HEAD returned 200. These are bounded server/media checks; rendered playback on a physical device was not observed.

## Continue or recover

Fetch the branch fix/afz-nuvio-public-edge-502-20261018 from f3arif/homelab-control. Source is under scripts/afz-nuvio-public-edge/20261018. Do not rerun the installer on an accepted existing installation: it refuses an existing task or busy proxy port.

Inspect the current task, current listener/process identity, private logs and current source hashes first. If the task is stopped and its dependencies/configuration remain correct, start **AFZ Nuvio Public Edge**. Preserve every existing Serve/Funnel mapping; this repair requires no Funnel reset or mapping update.

For an absent installation, copy Run-PublicEdge.ps1, Install-PublicEdge.ps1 and Rollback-PublicEdge.ps1 into the program directory above. The installer requires the existing healthy AFZ core, original proxy module, private transport token and unchanged original Funnel target. Run Install-PublicEdge.ps1 with the authorized Windows account capable of registering that task. It parses separately during deployment; run the native PowerShell parser before invoking a changed copy. A failed post-install acceptance invokes the scoped rollback.

The original proxy module is an existing dependency, not bundled or overwritten by this package. Do not replace it with a historical copy over newer work. This package preserves the separate expired-stream recovery (PR 271) and AFZ Internet (PR 272) deployments.

For independent verification, run verify_public.py with Python 3 and the private transport token file beside the script, named public-transport-token-private.txt. On Envy the verification copy already exists with mode 0600. Do not commit the token, provider files, selected URLs or raw logs. probe_routes.py runs on H3 and records sanitized before/after route status in the evidence directory.

Rollback-PublicEdge.ps1 removes only this task after checking its exact action, and stops only a matching recorded child after checking PID, creation time and command identity. It leaves source, core, tokens, other tasks and every Serve/Funnel mapping intact. Rollback restores the prior absence of the edge; the original public route would again return 502.

For the user, reopen the failing title's **Sources** page and retry. No add-on reinstall or phone restart is required by this server repair.
