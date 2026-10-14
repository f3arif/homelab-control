# Pixel 10 USB route diagnostics — 13 October 2026

Resume key: `AFZ-PIXEL10-USB-ROUTES-20261013`.

Pixel 10 Pro XL is attached to H3 by USB and is owned by existing ADB server 5038. Server 5037 initially showed only the unauthorized Pixel 8 USB device and Pixel 10 wireless entries; Windows PnP and server 5038 independently established the Pixel 10 USB connection. No ADB server was restarted or device authorization replaced. All Pixel 10 commands must use `-P 5038 -s 58211FDCQ003VJ` for this session. Device identity must be refreshed if access changes.

Fresh USB checks passed: public DNS/public ICMP, phone-to-H3 tailnet ICMP, one validated Tailscale VPN, and DNS/TCP reachability to both installed add-on hosts. H3 is Running with no health warnings. Installed preview is `0.5.1-afz-r33.1-account-link`; it was not installed or changed by this diagnostic step. Private logs have zero matching DNS/DERP/network/fatal patterns. These checks do not prove TLS, manifest fetch, media playback, or a fix for the intermittent fault.

One-shot H3 task `AFZ Pixel10 USB Route Capture 20261013` started 2026-10-14 00:59:04 UTC / 13 October 20:59:04 Eastern. It checks once per minute for 30 minutes, with a 35-minute hard runtime limit, no recurring trigger and no automatic repair/restart. First sample passed. Expected ordinary completion is around 21:29 Eastern. It survives chat/Commander interruption while the logged-in Windows session and phone USB connection remain available.

Compared with the prior completed recorder, this one tests DNS, the private H3 route and both installed add-on host TCP connections. If a probe fails while USB identity is verified, it captures resolver, connectivity, device-idle, Tailscale service and bounded process logs before any restart. USB disconnects are coverage gaps, not evidence of a network fault. USB/charging and periodic traffic can affect idle behavior; a controlled idle/cellular transition is not claimed. Endpoint probes are DNS/TCP only, not TLS or playback.

H3 private evidence and task scripts: `C:\AFZ\Evidence\Pixel10-Connectivity-20261013-2052\usb-5038`. Read `route-capture-status.json` and `route-capture-timeline.jsonl` after completion. Inspect any `route-fault-*` captures before applying a targeted fix. Do not rerun the guarded starter or the old 11 October starter. Preserve Pixel 8's accepted R32/R33 setup and completed download. Raw logs, network dumps, full tailnet inventory and protected add-on XML remain private and are excluded from Git.
