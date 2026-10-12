# Pixel 10 bounded connectivity capture

Resume key: `AFZ-PIXEL10-CAPTURE-REVIEWED-20261012`.

## Completed capture reviewed 12 October 2026

The one-shot capture completed on 11 October at 05:17:15 UTC / 01:17:15 Eastern with 20 samples. Every sample verified the USB device, an online current peer, exactly one connected Tailscale VPN, the same Tailscale process, and H3 Running with no health warnings. All bounded log captures succeeded; review found no matching DNS/DERP/network-failure/fatal patterns. Windows task LastTaskResult is 0 and NextRunTime is null. See `completion-summary.json`.

This does not diagnose or fix the intermittent problem. It covers a short USB-connected observation, without continuous application/DNS probes or a controlled idle/cellular transition. At the 12 October follow-up, H3 shared ADB server 5037 listed only the ONN box; Pixel 10 was absent from both USB and wireless entries. Reconnect Pixel 10 by USB to H3 before fresh phone-side verification. Preserve the phone's failing state and logs before restarting Tailscale. Do not rerun the guarded old starter or repeat accepted Pixel 8 media/setup tests.

## Original capture recipe and historical baseline

The 11 October baseline was healthy: public DNS/public ICMP and phone-to-H3 private-route ICMP passed. The exact current phone VPN address was read from the live Android VPN and matched to one H3 peer. The older duplicate Pixel 10 peer is offline and is not a valid replacement address. Tailscale is already in Android's device-idle allowlist. There is no confirmed cause for the intermittent failure and no corrective phone/network change has been made.

A one-shot Windows scheduled task `AFZ Pixel10 Connectivity Capture 20261011` started at 2026-10-11 05:07:15 UTC / 01:07:15 Eastern. It records about every 30 seconds for 10 minutes, with a 12-minute hard runtime limit and no recurring trigger. H3 execution continues independently of the chat/Commander terminal while the logged-in Windows session and Pixel 10 USB connection remain available. It has completed; no recurring trigger remains.

The captured command set is read-only. It verifies exact Pixel 10 model and USB serial, resolves the current VPN peer from live Android routing rather than an old saved address, then records peer status, VPN/process presence and bounded Tailscale logs. It captures additional resolver/idle/service state when a peer/process/VPN loss is observed. It does not restart Tailscale, alter DNS/VPN/ADB settings, change accounts, reinstall apps, or touch the accepted Pixel 8 media/setup state. USB/charging and ADB observations can affect sleep-related behavior; no controlled idle/mobile-data transition is claimed.

H3 evidence: `C:\AFZ\Evidence\Pixel10-Connectivity-20261011`.

After completion, inspect `capture-status.json` and `capture-timeline.jsonl` before doing anything else. If `completed_fault_captured`, correlate the event's `summary.json` with its private logs/network/resolver captures. If `completed_no_fault_observed`, the fault was not reproduced in this window; do not claim fixed. If `failed`, inspect the saved error and task state before retrying. Do not rerun `start-capture.ps1`: its existing task/state guards intentionally reject repeats. Raw logs, network dumps and full peer inventories stay private; only the sanitized checkpoint is included here.

Pixel 8 R32 media and R33 setup acceptance remain complete. R33 PR #266 retains its own patch/build/acceptance evidence; this diagnostic branch starts from current main and does not change application/backend code. OnePlus physical acceptance remains pending because that phone was not connected.
