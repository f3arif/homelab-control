# AFZ Home Assistant fleet MQTT publisher

This directory contains the single Phase-1 AFZ fleet telemetry publisher used by Home Assistant.

## Authority and data flow

- Live source: Control Hub `GET /api/state` only.
- MQTT base topic: `afz/fleet`.
- Home Assistant discovery prefix: `homeassistant`.
- Durable source/config/results: GitHub.
- OneDrive/SharePoint: never used for liveness or high-frequency state.
- The publisher has no job creation, routing, wake, restart, shell, SSH, PowerShell execution, firewall, authentication, ACL, or credential-changing authority.

The source-to-canonical-worker mapping is recorded in the canonical private control repo at `afz-control/homeassistant/worker-source-map.json`.

## Runtime model

`Publish-AFZ-Fleet-Mqtt.ps1` is one long-running process. It reads `/api/state` every 15 seconds by default, maps the live Control Hub records to the six canonical Home Assistant workers, and publishes retained state/discovery messages.

`Install-AFZ-Fleet-MqttPublisher.ps1` validates the script, runs a dry mapping pass, runs one MQTT canary, then creates one Windows Scheduled Task with an **At startup** trigger. Task Scheduler is only a process launcher; it is not used as a recurring poll scheduler. The task uses `IgnoreNew` so there is never more than one publisher instance.

The missing canonical ASUS source deliberately publishes unavailable. Missing numeric telemetry is never replaced with zero or copied from another physical host.

## Local secrets

The current broker path does not require repository credentials. If MQTT authentication is introduced later, the publisher can read `AFZ_MQTT_USERNAME` and `AFZ_MQTT_PASSWORD` from the local process environment. Do not commit those values.

## Safe validation

Read-only mapping only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Publish-AFZ-Fleet-Mqtt.ps1 -Once -DryRun
```

One-shot discovery/state publish:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Publish-AFZ-Fleet-Mqtt.ps1 -Once
```

Guarded installer validation without task creation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AFZ-Fleet-MqttPublisher.ps1 -ValidateOnly
```
