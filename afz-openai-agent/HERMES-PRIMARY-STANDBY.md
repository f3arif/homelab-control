# Hermes Primary / Standby Topology

Status: ACTIVE / HEALTHY

## Roles

- Primary host: `DESKTOP-H3R6CQN` (H3)
- Standby host: `DESKTOP-10SKF0M` (ASUS / windows-main)
- H3 local fallback: `qwen3.6:35b-a3b-hermes64k`
- ASUS emergency local fallback: `qwen3.5:4b-hermes96k`

## H3 routing order

1. GPT-5.6 Sol through the pooled OpenAI OAuth credentials.
2. GPT-6 Astra through the same OpenAI OAuth pool.
3. OpenRouter model lanes.
4. H3 local 35B/64K model.

## Verified H3 state

- two OpenAI OAuth credentials
- OpenRouter credential
- Hermes gateway running
- Desktop Commander 0.2.48 online on the original device identity
- five-minute Desktop Commander watchdog
- H3 router present
- H3 local 35B fallback verified

## Verified ASUS standby state

- standby role marker present
- two OpenAI OAuth credentials
- OpenRouter credential
- Desktop Commander 0.2.48 online
- AFZ typed agent 8796 healthy
- AFZ control 8797 healthy
- default Hermes router test: `ASUS_STANDBY_OK`
- local-only fallback test: `ASUS_LOCAL_STANDBY_OK`
- local fallback model: `qwen3.5:4b-hermes96k`

## Control-core recovery

The September 9 control-core revision introduced a malformed route insertion. The newest parse-valid control core from September 5 was restored to GitHub and ASUS. Canonical recovery commit: `507bef13c23b7c9fd3fb3bd73d07b341258b4e7c`.

The repaired control core parses with zero PowerShell parser errors. The existing protected SYSTEM control task subsequently recovered automatically and restored port 8797.

## Primary / standby health monitor

H3 runs `Watch-Hermes-PrimaryStandby.ps1` every five minutes.

It checks:
- H3 Hermes gateway
- H3 router
- H3 Ollama
- ASUS Tailscale reachability
- ASUS typed agent 8796
- ASUS legacy control 8797
- ASUS SSH and WinRM reachability

If ASUS disappears from Tailscale, H3 sends Wake-on-LAN and checks again.

Current healthy classification: `PRIMARY_AND_STANDBY_READY`

State: `C:\ProgramData\AFZ\HermesRouting\health.json`

Log: `C:\ProgramData\AFZ\HermesRouting\health.log`

Latest scheduled health task result: `0`.

## Gateway host-level HA (Telegram failover)

ASUS runs `Watch-Hermes-Gateway-HA.ps1` (SYSTEM, every 1 minute, task `AFZ Hermes Gateway HA Watcher`):

- Probes the H3 Hermes gateway over the existing ASUS→H3 SSH trust (Tailscale first, LAN host-key-alias fallback). The probe checks gateway processes, an established Telegram API connection (149.154.x / 91.108.x), gateway log freshness, and Ollama.
- Classifications: `h3GatewayHealthy`, `h3GatewayDown`, `h3TelegramNotEstablished`, `h3HostUnreachable`, `h3SshProbeUnavailable`. Only the first plus the explicit failure classes count toward promotion; ambiguous probe results never promote (anti split-brain).
- Promotion: 3 consecutive failed checks → starts the ASUS native Hermes gateway through the user-context task `AFZ Hermes Gateway HA User Action` (S4U as Faiz — the gateway needs the user's Hermes home, config, and credentials; no stored password, no UAC), verifies the process and Telegram connection, writes `ACTIVE_HOST=ASUS`.
- Demotion: 3 consecutive healthy H3 checks → stops the ASUS gateway first (deliberate handover gap; duplicate Telegram polling is never knowingly allowed), re-probes H3 over SSH, then marks `ACTIVE_HOST=H3`. If H3 cannot be verified after the stop, the ASUS gateway is restarted (fail-safe rollback).
- While `ACTIVE_HOST=H3`, any ASUS gateway process found polling is stopped (invariant enforcement).
- While `ACTIVE_HOST=ASUS` and H3 host is up but its gateway is down, the watcher assists H3 recovery by invoking `hermes gateway start` over the existing SSH trust (cooldown 5 min, max 3 per outage).
- Simulation flag `C:\ProgramData\AFZ\HermesRouting\gateway-ha-simulate.flag` (via request-gated `Invoke-Hermes-Gateway-HAControl.ps1`) makes the watcher treat the H3 gateway as failed WITHOUT touching H3 — safe test path.

State: `C:\ProgramData\AFZ\HermesRouting\gateway-ha.json` (activeHost, primaryHost, standbyHost, consecutivePrimaryFailures, consecutivePrimarySuccesses, lastPromotion, lastDemotion, reason, h3/asus gateway health, last check time).

Log: `C:\ProgramData\AFZ\HermesRouting\gateway-ha.log`

Deployment: the AFZ OpenAI Agent updater postsync hook `HERMES_GATEWAY_HA_POSTSYNC_HOOK_V1` calls `Ensure-Hermes-Gateway-HA.ps1` (fail-closed: host guard, PS 5.1 parse gate on both scripts, registration only, no gateway lifecycle actions). Control requests go through `Invoke-Hermes-Gateway-HAControl.ps1` + `requests\hermes-gateway-ha-control.json` (one-shot per id, host-guarded).

## Security boundary

No ASUS agent allowlists were widened. No new SSH or WinRM trust was added. HP Envy diagnostic-only execution scope was left unchanged. H3 remains the primary execution authority.
