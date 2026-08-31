# AFZ GitHub-primary project transport policy

**Status:** ACTIVE / GLOBAL  
**Workflow:** `AFZ-AUTOMATION-FABRIC-V1`  
**Effective:** 2026-08-27  
**Latest authority refresh:** 2026-08-31

This is the current global AFZ transport/coordination policy. GitHub is the authoritative active source, coordination, handoff, and durable-result plane. OneDrive/SharePoint is a backup-only mirror and must never become an execution or control dependency.

## Authority model

### Live execution plane

Use Control Hub/PostgreSQL/Direct Fabric and the existing typed AFZ agent/API paths for live jobs, claims, leases, retries, worker health, resource gating, runtime execution, and execution authority.

Do not move high-frequency telemetry, live lease state, or worker-authority decisions into GitHub or OneDrive.

### GitHub-primary source / coordination / results plane

GitHub is the normal active and authoritative path for:

- source code, configuration, schemas, and policy
- project coordination and canonical control threads
- project status and next action
- durable handoffs and continuation notes
- blockers and review notes
- commits and pull requests
- durable execution evidence and material result summaries
- worker-to-project durable result/status reporting

For managed GitHub projects, workers and chats must read the fresh GitHub branch/ref before editing or continuing work. Material execution results must be reconciled into the canonical GitHub project thread.

GitHub is not proof that a worker is healthy, awake, eligible, or authorized to execute a lane; fresh Direct Fabric/Control Hub state remains authoritative for those decisions.

### OneDrive / SharePoint backup-only plane

OneDrive/SharePoint is a **backup-only mirror** for sanitized durable artifacts and result summaries. It is not a live control or execution plane.

Where a practical OneDrive backup destination is available, AFZ automation should make a best-effort backup copy of important durable policy/config snapshots and material sanitized result summaries after the authoritative GitHub state is written. Backup failure or sync delay MUST NOT block, roll back, retry, or change the status of the GitHub/Direct Fabric operation.

Normal AFZ automation MUST NOT use OneDrive/SharePoint as:

- request queue or trigger source
- script-transfer execution queue
- canonical result queue or result-ingress authority
- liveness/heartbeat store
- lease, claim, retry, or worker-state transport
- source synchronization authority
- routine cross-chat continuation authority
- normal project coordination/control source

Normal automation MUST NOT poll OneDrive/SharePoint for work or wait on sync propagation. Never use OneDrive state to override fresher GitHub or Direct Fabric state.

Backup copies must be sanitized: never mirror API keys, bearer tokens, private keys, passwords, credential-bearing URLs, secret-bearing environment output, or customer-sensitive raw diagnostics.

If GitHub durable communication is temporarily unavailable, keep live execution state in Control Hub/local durable state. OneDrive may preserve a backup/emergency record, but it does not become authoritative. Reconcile any such record back into GitHub when GitHub is available.

## Source workflow

When a project has a dedicated GitHub repository:

1. Read the fresh remote branch/ref before editing.
2. Pin the exact commit SHA used for worker synchronization where practical.
3. Use fast-forward-only pulls for managed worktrees.
4. Never force-reset a dirty worktree or silently discard/stash unknown changes.
5. Push normal non-force commits only.
6. Use PRs for material policy/schema/control changes when practical.
7. After GitHub is authoritative, make a best-effort OneDrive backup of material sanitized artifacts where the project has a configured backup destination.

When a project does not yet have its own repository, use the private AFZ control repository and its canonical project control issue for durable coordination until the project is split into a dedicated repository.

## Worker / result workflow

- Runtime execution occurs through the current typed AFZ API/Control Hub/Direct Fabric path.
- Durable status/results/evidence go to GitHub first and remain authoritative there.
- Important sanitized results may also be mirrored to OneDrive as backup-only copies.
- Material results must be summarized in the canonical GitHub project thread so future chats and workers have durable context.
- Preserve chat/manual control as a fallback path where already supported, without making it the primary automation transport.
- Do not paste secrets or sensitive raw command output into GitHub or OneDrive backups.

## Safety and compatibility boundaries

- Never commit or mirror API keys, bearer tokens, private keys, passwords, credential-bearing URLs, or secret-bearing environment output.
- Preserve existing typed-tool and lane authority boundaries.
- Preserve no-dual-execution rules during migration.
- A OneDrive backup is never a second execution request.
- Do not create a competing scheduler/database/controller solely to support GitHub transport or OneDrive backup.
- H3 generic readiness, H3 direct diagnostic readiness, and specialized model/project authority remain separate.

## Migration / compliance rule

A project is compliant when:

1. it has a canonical GitHub control thread;
2. GitHub is used for normal source/coordination/durable result evidence;
3. future durable status/handoffs go to GitHub first;
4. OneDrive/SharePoint is used only for best-effort backup copies and never as a routine trigger/queue/control authority;
5. live execution continues through the current typed/direct execution plane;
6. OneDrive backup failures never block or change authoritative GitHub/Direct Fabric state;
7. legacy SharePoint/OneDrive automation files are treated as backup/recovery material, not live truth.
