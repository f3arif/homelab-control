# FamilyPTT GitHub transport policy

Status: ACTIVE / LINKED

FamilyPTT follows the AFZ GitHub-first control/source workflow.

## Repository

- Project repository: `f3arif/FamilyPTT`
- Visibility: private
- Canonical branch: `main`
- Windows project path: `C:\Projects\FamilyPTT`
- Dedicated local remote: `github`
- Migration baseline: `731e673d6804cf7e87c2fdb3feb95c56eb3e1966`
- Current migrated source commit at link completion: `f594844363427e6f4e1421d5038b102ff0e85b49`

## Source and control path

```text
ChatGPT / GitHub connector
        |
        | read current branch/commit, write reviewed source/control commits
        v
f3arif/FamilyPTT (private, main)
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
2. GitHub is the transport for FamilyPTT source/config/control changes. Read the current GitHub state before editing and push resulting source changes back through GitHub.
3. Workers must refresh from GitHub before starting a new FamilyPTT change. Resolve the fresh branch ref first, then use the exact commit SHA for the sync payload. Do not rely on cached branch ZIPs.
4. Worker pulls are fast-forward-only. Never force-reset a dirty FamilyPTT worktree, silently discard local changes, or auto-stash unknown work.
5. Worker pushes are normal non-force pushes only. Never force-push, rewrite remote history, delete a branch, or expose credentials/tokens in output.
6. Same-project state-changing work remains serialized. Independent read-only validation may run in parallel.
7. Runtime diagnostics/results return through the local AFZ typed-agent/API path; do not create SharePoint result files as the normal continuation path.
8. If GitHub becomes unreachable or the FamilyPTT remote is not usable, stop source mutation and return a transport/link failure instead of silently falling back to the SharePoint queue.
9. Existing sealed FamilyPTT functional evidence remains valid unless affected source paths change. Do not rerun microphone/media tests solely because the transport workflow changed.
10. Secrets, bearer tokens, JWTs, API keys, remote credentials, and credential-bearing Git URLs must never be printed or committed.
11. Local runtime artifacts, phase-0 exports, automation scratch/backups, and source backup copies are excluded from the project repository; only active product/config source is authoritative in GitHub.

## Migration status

The dedicated private FamilyPTT repository is linked and visible to the connected GitHub installation. The current active application/config source was migrated to `main`, backup/runtime artifacts were excluded, secret-pattern gates passed, and the local worktree was clean at migration completion.

The SharePoint worker queue was used only as the one-time bootstrap path required to create/link/push the repository from the existing Windows worktree. It is now retired for normal FamilyPTT continuation. All subsequent FamilyPTT pull/push/source-control work must use GitHub-first transport.
