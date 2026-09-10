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

H3 has:

- two OpenAI OAuth credentials,
- one OpenRouter credential,
- Hermes gateway persistence,
- Desktop Commander 0.2.48 on the original device identity,
- a five-minute Desktop Commander self-heal watchdog,
- the benchmark-informed router under `C:\Projects\HermesRouter`,
- the local 35B/64K Ollama fallback.

## Standby health

H3 runs `Watch-Hermes-PrimaryStandby.ps1` every five minutes.

The watchdog checks:

- H3 Hermes gateway,
- H3 router file,
- H3 loopback Ollama,
- ASUS Tailscale reachability,
- ASUS AFZ agent port 8796,
- ASUS SSH and WinRM reachability.

If ASUS stops responding to Tailscale, H3 sends Wake-on-LAN to the known ASUS LAN NIC and checks again.

State is written to:

`C:\ProgramData\AFZ\HermesRouting\health.json`

Log:

`C:\ProgramData\AFZ\HermesRouting\health.log`

Healthy classification:

`PRIMARY_AND_STANDBY_READY`

## Security boundary

Do not widen ASUS AFZ-agent allowlists merely to recover Commander.

H3 does not receive ASUS passwords or privileged SSH credentials. HP Envy relay services retain their existing diagnostic-only scopes.

ASUS may be network-ready as standby even if its user-level Desktop Commander session is offline. The primary execution authority remains H3.

## Current validation

Latest validated state on September 9, 2026:

- H3 health: ready
- H3 Hermes gateway: running
- H3 router: present
- H3 Ollama: healthy
- ASUS Tailscale: reachable
- ASUS port 8796: reachable
- ASUS SSH: reachable
- ASUS WinRM: reachable
- watchdog scheduled every 5 minutes
- watchdog LastResult: 0
- classification: `PRIMARY_AND_STANDBY_READY`
