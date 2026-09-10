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

## Security boundary

No ASUS agent allowlists were widened. No new SSH or WinRM trust was added. HP Envy diagnostic-only execution scope was left unchanged. H3 remains the primary execution authority.
