# AFZ GitHub-primary project transport policy

**Status:** ACTIVE / GLOBAL  
**Workflow:** `AFZ-AUTOMATION-FABRIC-V1`  
**Effective:** 2026-08-27  
**Latest authority refresh:** 2026-08-27

This is the current global AFZ transport/coordination policy. It incorporates the latest GitHub-primary workflow rule now used by AFZ result-ingress work.

## Authority model

### Live execution plane

Use Control Hub/PostgreSQL/Direct Fabric and the existing typed AFZ agent/API paths for live jobs, claims, leases, retries, worker health, resource gating, runtime execution, and execution authority.

Do not move high-frequency telemetry, live lease state, or worker-authority decisions into GitHub.

### GitHub-primary source / coordination / results plane

GitHub is the normal active path for:

- source code, configuration, schemas, and policy
- project coordination and canonical control threads
- project status and next action
- durable handoffs and continuation notes
- blockers and review notes
- commits and pull requests
- durable execution evidence and material result summaries
- worker-to-project durable result/status reporting

For managed GitHub projects, workers and chats should read the fresh GitHub branch/ref before editing or continuing work. Material execution results must be reconciled into the canonical GitHub project thread.

GitHub is not proof that a worker is healthy, awake, eligible, or authorized to execute a lane; fresh Direct Fabric/Control Hub state remains authoritative for those decisions.

### OneDrive / SharePoint emergency-only plane

OneDrive/SharePoint is **emergency backup/handoff/archive only** for AFZ automation communication.

Normal AFZ automation MUST NOT use OneDrive/SharePoint as:

- request queue
- script transfer queue
- result queue or normal result-ingress path
- liveness/heartbeat store
- worker state transport
- source synchronization bus
- routine cross-chat continuation/handoff bus
- normal project coordination or control source

Do not create a SharePoint/OneDrive queue, result file, or handoff simply because an older workflow used that pattern.

Normal automation MUST NOT poll OneDrive/SharePoint or wait on sync propagation.

If GitHub durable communication is unavailable, keep live execution state in Control Hub/local durable state. Use OneDrive/SharePoint only under an explicitly declared `EMERGENCY_FALLBACK` when a durable emergency handoff is genuinely required. The emergency record must include the project and timestamp and must be reconciled back into the canonical GitHub project thread when GitHub becomes available.

## Source workflow

When a project has a dedicated GitHub repository:

1. Read the fresh remote branch/ref before editing.
2. Pin the exact commit SHA used for worker synchronization where practical.
3. Use fast-forward-only pulls for managed worktrees.
4. Never force-reset a dirty worktree or silently discard/stash unknown changes.
5. Push normal non-force commits only.
6. Use PRs for material policy/schema/control changes when practical.

When a project does not yet have its own repository, use the private AFZ control repository and its canonical project control issue for durable coordination until the project is split into a dedicated repository.

## Worker / result workflow

- Runtime execution may occur through the current typed AFZ API/Control Hub/Direct Fabric path.
- Durable status/results/evidence go to GitHub, not OneDrive/SharePoint.
- Material results must be summarized in the canonical GitHub project thread so future chats and workers have durable context.
- Preserve chat/manual control as a backup path where already supported, without making it the primary automation transport.
- Do not paste secrets or sensitive raw command output into GitHub.

## Safety and compatibility boundaries

- Never commit or comment API keys, bearer tokens, private keys, passwords, credential-bearing URLs, or secret-bearing environment output.
- Preserve existing typed-tool and lane authority boundaries.
- Preserve no-dual-execution rules during migration.
- Do not create a competing scheduler/database/controller solely to support GitHub transport.
- H3 generic readiness, H3 direct diagnostic readiness, and specialized model/project authority remain separate.

## Migration / compliance rule

A project is GitHub-primary when:

1. it has a canonical GitHub control thread;
2. GitHub is used for normal source/coordination/durable result evidence;
3. future durable status/handoffs go to GitHub;
4. SharePoint/OneDrive queue/result/handoff generation is disabled or unused for normal continuation;
5. live execution continues through the current typed/direct execution plane;
6. any remaining legacy SharePoint/OneDrive automation files are treated as emergency recovery material, not live truth.
