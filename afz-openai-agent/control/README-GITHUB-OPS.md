# AFZ GitHub Ops Control Plane

Status: staged on main-compatible repository layout.

Canonical repository: `f3arif/homelab-control`

Transport priority:
1. Direct Fabric / local API
2. GitHub control plane
3. OneDrive emergency queue
4. Manual PowerShell/chat paste

Canonical GitHub worker lanes live under `afz-openai-agent/control/` and use one control branch (`github-ops`) once cutover validation passes. OneDrive remains a fallback during migration.

No legacy branches or OneDrive workers are removed by this change.
