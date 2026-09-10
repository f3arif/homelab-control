# Hermes Primary / Standby Topology

Status: ACTIVE

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

Hermes automatically rotates pooled OpenAI OAuth credentials when one account is exhausted.

## H3 verified state

H3 has two OpenAI OAuth credentials, OpenRouter, Hermes gateway persistence, Desktop Commander 0.2.48 on its original device identity, a five-minute Commander self-heal watchdog, the benchmark-informed router, and the 35B/64K Ollama fallback.

## Primary / standby health monitor

H3 runs `Watch-Hermes-PrimaryStandby.ps1` every five minutes.

It checks H3 gateway/router/Ollama health and ASUS Tailscale, AFZ agent 8796, control 8797, SSH, and WinRM reachability. If ASUS disappears from Tailscale, H3 sends Wake-on-LAN and checks again.

State: `C:\ProgramData\AFZ\HermesRouting\health.json`

Log: `C:\ProgramData\AFZ\HermesRouting\health.log`

Classifications distinguish network reachability from actual control readiness. ASUS is not considered fully ready merely because the machine is powered on.

## Security boundary

Do not widen ASUS AFZ-agent allowlists merely to recover Commander. H3 does not receive ASUS passwords or privileged SSH credentials. HP Envy relay services retain their existing diagnostic-only scope.

## Current state — September 9, 2026

Current classification: `PRIMARY_READY_STANDBY_CONTROL_DEGRADED`

H3:
- ready: true
- Hermes gateway: true
- router: true
- Ollama: true

ASUS:
- networkReady: true
- Tailscale: true
- AFZ agent 8796: true
- SSH 22: true
- WinRM 5985: true
- controlReady: false
- control 8797: false
- Desktop Commander: offline
- Windows-main worker heartbeat: stale

A bounded repair job is queued for ASUS and the canonical repair script is `Repair-ASUS-Hermes-Standby.ps1`. When ASUS's worker or an authorized control channel returns, that job repairs Commander, writes the standby role marker, and smoke-tests the ASUS router.
