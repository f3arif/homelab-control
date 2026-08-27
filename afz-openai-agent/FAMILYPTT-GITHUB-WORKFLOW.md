# FamilyPTT GitHub transport policy

Status: ACTIVE

FamilyPTT follows the AFZ GitHub-first control/source workflow.

## Source and control path

```text
ChatGPT / GitHub connector
        |
        | read current branch/commit, write reviewed source/control commits
        v
GitHub project/control repository
        |
        | worker sync: fresh branch ref -> exact commit SHA -> SHA-pinned archive or git fetch
        v
C:\Projects\FamilyPTT on the selected AFZ worker
        |
        | typed local execution / validation
        v
AFZ OpenAI Agent result -> ChatGPT
```

## Rules

1. Do not use OneDrive or SharePoint as the FamilyPTT request, script, result, liveness, or source-sync bus.
2. GitHub is the transport for source/config/control changes. ChatGPT should read the current GitHub state before editing and push the resulting commit through GitHub.
3. Workers must refresh from GitHub before starting a new FamilyPTT change. Resolve the fresh branch ref first, then use the exact commit SHA for the sync payload. Do not rely on cached branch ZIPs.
4. Worker pulls are fast-forward-only. Never force-reset a dirty FamilyPTT worktree, silently discard local changes, or auto-stash unknown work.
5. Worker pushes are normal non-force pushes only. Never force-push, rewrite remote history, delete a branch, or expose credentials/tokens in output.
6. Same-project state-changing work remains serialized. Independent read-only validation may run in parallel.
7. Runtime diagnostics/results return through the local AFZ typed-agent/API path; do not create SharePoint result files as the normal continuation path.
8. If the FamilyPTT project repository/remote is not yet linked, return `REPO_NOT_LINKED` and perform only read-only local inspection. Do not silently fall back to the SharePoint queue.
9. Existing sealed FamilyPTT functional evidence remains valid unless affected source paths change. Do not rerun microphone/media tests solely because the transport workflow changed.
10. Secrets, bearer tokens, JWTs, API keys, remote credentials, and credential-bearing Git URLs must never be printed or committed.

## Current migration requirement

The AFZ GitHub connector can access the control repository, but a dedicated FamilyPTT repository is not currently visible to the connected GitHub installation. Until that project repository/remote is linked, control-policy updates can flow through `f3arif/homelab-control`, while FamilyPTT source mutation must not be routed through the legacy SharePoint execution bus.
