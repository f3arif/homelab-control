# AFZ Hermes-first Project Execution Router

Status: ACTIVE DESIGN / REVERSIBLE

Resume key: `AFZ-HERMES-PROJECT-EXEC-ROUTER-R1-20260915`

## Purpose

Normal AFZ project work should continue even when Desktop Commander is unavailable. The default route is Hermes in the existing windows-main user context, with Desktop Commander retained as an explicit fallback.

Normal flow:

`ChatGPT or another AFZ account -> GitHub durable request/source -> windows-main local router -> Hermes guarded project-edit lane -> fixed validation -> portable result/handoff`

## Performance

- The router watches only local files at 750 ms; it does not poll OneDrive or the network.
- Existing exact-SHA GitHub sync and fast-signal behavior is reused.
- Hermes uses the existing configured user context, providers, skills, and checkpoints.
- Automated human-delay pacing is disabled.
- Validation uses fixed direct commands rather than a second model pass.

## Request contract

Canonical request: `afz-openai-agent/requests/project-task.json`.

When active, provide a unique `request_id`, `project`, `project_root`, and `task`. Optional controls include `resume_key`, `cross_chat_note`, `force_route`, `validation_profile`, `max_turns`, `timeout_seconds`, `allow_web`, `model`, and `expected_source_sha`.

Routes are `auto`, `hermes`, or `commander`. Validation profiles are `none`, `git-status`, `android`, `dotnet`, `node`, or `python`. A new task must always use a new request ID; completed IDs are intentionally idempotent.

## Guarded Hermes lane

The automated Hermes lane enables file editing, skills, and optional web research. Terminal/process tools are not exposed to the model in this lane. File writes are restricted to the requested project root, checkpoints are required, and unsafe bypass mode is not enabled.

Existing dirty worktrees are preserved. The router records pre/post Git state and never automatically resets, cleans, discards, or stashes user work.

## Fixed validation

After Hermes edits, the wrapper may run one allowlisted validation profile:

- `git-status`: branch/status read
- `android`: Gradle tests then lint
- `dotnet`: `dotnet test`
- `node`: package test script when present
- `python`: pytest
- `none`: no validation command

The request schema intentionally has no arbitrary shell-command field. Add another named profile in source control if a project needs a new repeatable validation action.

## Commander fallback and rollback

Per-task rollback: set `force_route` to `commander`.

Global rollback: set `default_route` to `commander` in `control/project-execution-router.json`. Restore normal routing by setting it back to `hermes`.

Commander fallback is automatic only when Hermes fails before project mutation begins. Once Hermes may have modified a worktree, the router blocks a second executor until that worktree is reviewed. This prevents duplicate or conflicting edits.

If Commander must be reauthorized, the existing local pairing launcher remains available as a separate operator-controlled recovery path; authentication material is not written into GitHub or OneDrive.

## Cross-chat and cross-account continuation

Canonical handoff: `afz-openai-agent/control/AFZ-PROJECT-EXECUTION-HANDOFF-LATEST.md`.

Runtime diagnostic mirrors, when the existing OneDrive folder is present:

- `ChatGPT_Termius/AFZ-PROJECT-EXECUTION-LATEST.json`
- `ChatGPT_Termius/AFZ-OTHER-ACCOUNT-PROJECT-EXECUTION-LATEST.txt`

These carry request identity, route, source SHA, Git snapshots, validation state, resume key, and next action. They are diagnostics only and are never command input.

windows-main runtime state lives under `C:\ProgramData\AFZ\ProjectExecution` with `latest.json`, `pending.json`, `result.json`, `history`, and `install.json`.

Scheduled tasks:

- `AFZ Project Task Router Watcher` — SYSTEM, local sub-second dispatcher
- `AFZ Hermes Project Task User Action` — user-context, on-demand executor

## Continuation

Use resume key `AFZ-HERMES-PROJECT-EXEC-ROUTER-R1-20260915`, read the handoff, refresh the latest runtime mirror, inspect live Git state, and continue the recorded next action. Do not repeat completed milestones merely because the chat or account changed.
