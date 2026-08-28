# AFZ Prospect Engine

The Prospect Engine is served by the existing AFZ OpenAI Agent at `/prospects`.

- Source: this GitHub directory
- Runtime data: `C:\ProgramData\AFZ\ProspectEngine\prospects.json`
- Audit log: `C:\ProgramData\AFZ\ProspectEngine\audit.ndjson`
- Runtime transport: local/Tailscale HTTP on the existing allowlist
- Research: OpenAI Responses API with hosted `web_search` and strict JSON schema
- Outlook: delegated Microsoft Graph `Mail.ReadWrite`; draft creation only

No OneDrive or SharePoint path is used for search, lead state, review state, or draft creation.

## One-time Outlook setup

Create a Microsoft Entra app registration for the AFZ tenant, enable public-client/device-code authentication, and add delegated Microsoft Graph permissions:

- `User.Read`
- `Mail.ReadWrite`
- `offline_access`

Paste the application (client) ID and tenant ID/domain into the Outlook setup panel, then use **Connect Outlook**. The refresh token is encrypted with Windows DPAPI `LocalMachine`; no client secret is used.

The service exposes no Microsoft Graph send route. A lead must have a verified public business email, contact evidence URL, completed compliance checklist, and explicit review before the Draft button is enabled.
