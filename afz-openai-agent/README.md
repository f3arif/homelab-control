# AFZ OpenAI Agent v1

Replaces the OneDrive/SharePoint execution bus for AFZ live operations with a local typed-tool agent that calls the OpenAI Responses API outbound.

## Data path

```text
Browser / AFZ Ops Console
        |
        v
Windows-main AFZ OpenAI Agent :8796
        |
        +-- typed local read tools --> Jellyfin / AFZ files / backups
        |
        +-- HTTPS outbound --> OpenAI Responses API
                |
                +-- function_call
                +-- local tool result
                +-- function_call_output
                +-- final answer
```

OneDrive is not used for request transport, job state, tool output, or liveness.

## V1 safety

V1 intentionally exposes only read-only tools:

- `afz_system_status`
- `afz_read_file`
- `afz_list_files`
- `afz_search_files`
- `jellyfin_public_info`
- `jellyfin_regression_forensic`
- `jellyfin_user_views`
- `jellyfin_recent_diagnostic_report`

No arbitrary PowerShell tool is exposed to the model. File operations are confined to named root aliases. Jellyfin forensic/database reads use fixed scripts and SQLite read-only mode. Active Jellyfin tokens may be tested locally by `jellyfin_user_views`, but token values are never returned to the model.

If the model concludes that a mutation is required, V1 returns `APPROVAL_REQUIRED` with the evidence. A later R1 tool can implement the exact reversible repair without broad shell access.

## Install once on Windows-main

Run an elevated PowerShell after this folder is on `main`:

```powershell
$u='https://raw.githubusercontent.com/f3arif/homelab-control/main/afz-openai-agent/Install-AFZ-OpenAI-Agent.ps1'
$p="$env:TEMP\Install-AFZ-OpenAI-Agent.ps1"
Invoke-WebRequest $u -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

The installer:

1. Clones or fast-forwards `C:\AFZ\homelab-control` from GitHub.
2. Reuses `OPENAI_API_KEY` if already configured; otherwise prompts once.
3. Encrypts the key using Windows DPAPI `LocalMachine` and ACLs the key file to SYSTEM/Administrators.
4. Registers `AFZ OpenAI Agent` as a SYSTEM scheduled task at startup.
5. Registers `AFZ OpenAI Agent Updater`, which fast-forwards GitHub `main` every 15 minutes and restarts the service only when the commit changes.
6. Opens TCP 8796 only to HP Envy's Tailscale address for cross-host integration.
7. Creates a desktop shortcut to the local agent UI.

## Local UI

Open:

```text
http://127.0.0.1:8796/
```

AFZ Prospect Engine:

```text
http://127.0.0.1:8796/prospects
```

The Prospect Engine searches and verifies public Ontario business websites, stores leads and edited drafts under `C:\ProgramData\AFZ\ProspectEngine`, and can create explicitly reviewed Outlook drafts through delegated Microsoft Graph access. It has no email-send endpoint and does not use OneDrive/SharePoint for runtime state.

Then requests can be as short as:

```text
Continue fixing the Jellyfin TorBox library regression. Diagnose from live state and known-good backups.
```

## API

Health:

```http
GET http://127.0.0.1:8796/health
```

Agent request:

```http
POST http://127.0.0.1:8796/api/request
Content-Type: application/json

{
  "processor": "auto",
  "project": "torbox",
  "prompt": "Continue diagnosing the Jellyfin TorBox regression."
}
```

The response shape is compatible with the AFZ request-console concept and includes `answer`, `model`, `state`, `id`, and `toolTrace`.

## OpenAI API implementation

The agent uses the Responses API function-calling loop:

1. Create a response with typed tools.
2. Inspect `response.output` for `function_call` items.
3. Execute the matching local allowlisted function.
4. Send `function_call_output` with the call ID and `previous_response_id`.
5. Continue until the response contains no function calls.

`parallel_tool_calls` is disabled so local actions are serialized and easier to audit.

## Next phase

After the Jellyfin regression is diagnosed, add narrowly scoped R1 tools for the exact repair and a policy/approval broker. The agent's updater makes those additions deploy automatically after they are merged to `main`; no OneDrive queue or per-job script transfer is required.
