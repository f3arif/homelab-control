# AFZ GitHub-first project transport policy

**Status:** ACTIVE / GLOBAL  
**Workflow:** `AFZ-AUTOMATION-FABRIC-V1`  
**Effective:** 2026-08-27

This policy generalizes the existing FamilyPTT GitHub-first pattern to all AFZ projects.

## Planes

### Live execution

Use Control Hub/PostgreSQL/Direct Fabric and the existing typed AFZ agent/API paths for live jobs, claims, leases, retries, worker health, resource gating, runtime tool output, and execution authority.

Do not move high-frequency telemetry or live lease state into GitHub.

### Durable project communication

Use GitHub for:

- project status and next action
- durable handoffs and continuation notes
- blockers and review notes
- code/source/config/policy/schema changes
- commits and pull requests
- references to completed execution results
- canonical project control threads

GitHub is the durable collaboration/history plane; Control Hub remains the live execution plane.

### OneDrive/SharePoint

OneDrive/SharePoint is emergency backup/archive only for automation communication.

Normal AFZ automation MUST NOT use it as:

- request queue
- script transfer queue
- result queue
- liveness/heartbeat store
- worker state transport
- source synchronization bus
- routine cross-chat continuation/handoff bus

Do not create a new SharePoint result/handoff simply because a project previously used that pattern.

If GitHub durable communication is unavailable, live execution state may remain in Control Hub/local durable state. Do not silently fall back to SharePoint. An emergency fallback must be explicit and reconciled back to GitHub afterward.

## Source workflow

When a project has a dedicated GitHub repository:

1. Read the fresh remote branch/ref before editing.
2. Pin the exact commit SHA used for worker synchronization where practical.
3. Use fast-forward-only pulls for managed worktrees.
4. Never force-reset a dirty worktree or silently discard/stash unknown changes.
5. Push normal non-force commits only.
6. Use PRs for material policy/schema/control changes when practical.

When a project does not yet have its own repository, use the private AFZ control repository/project control issue for durable communication until the project is split into a dedicated repository.

## Worker/result workflow

- Runtime execution results may return directly through the typed AFZ API/Control Hub path.
- Material results must be summarized into the canonical GitHub project thread so future chats and workers have durable context.
- Do not paste secrets or sensitive raw command output into GitHub.
- Do not infer worker health or execution authority from GitHub activity.

## Safety boundaries

- Never commit or comment API keys, bearer tokens, private keys, passwords, credential-bearing URLs, or secret-bearing environment output.
- Preserve existing typed-tool and lane authority boundaries.
- Preserve no-dual-execution rules during migration.
- H3 generic readiness, H3 direct diagnostic readiness, and specialized model/project authority remain separate.

## Migration rule

A project is considered GitHub-first for communication when:

1. it has a canonical GitHub control thread;
2. future durable status/handoffs go there;
3. SharePoint queue/result/handoff generation is disabled or no longer used for normal continuation;
4. live execution continues through the current typed/direct execution plane;
5. any remaining legacy SharePoint files are treated as emergency archive, not live truth.
