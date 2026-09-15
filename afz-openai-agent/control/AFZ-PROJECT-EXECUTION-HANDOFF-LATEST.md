# AFZ Project Execution Router — Cross-Chat Handoff

**Resume key:** `AFZ-HERMES-PROJECT-EXEC-ROUTER-R1-20260915`

## Purpose

This is the canonical cross-chat/cross-account pointer for machine-backed AFZ project work. It lets another ChatGPT account, Hermes session, or operator resume the current execution workflow without depending on Desktop Commander being available.

## Routing contract

1. Hermes/Direct Fabric is the normal project-task route.
2. H3 (`DESKTOP-H3R6CQN`) is the Hermes primary execution authority when the requested project/data is available there.
3. windows-main (`DESKTOP-10SKF0M`) is the Hermes standby and local-data execution route for Windows-local worktrees.
4. Desktop Commander remains the fallback/rollback transport.
5. OneDrive is diagnostic/handoff mirroring only; it is never the execution queue or lease authority.
6. GitHub remains durable source/coordination; runtime task state remains local Direct Fabric state.

## Files to read in order

1. `afz-openai-agent/control/project-execution-router.json`
2. `afz-openai-agent/requests/project-task.json`
3. `afz-openai-agent/PROJECT-EXECUTION-ROUTER.md`
4. this handoff file
5. refresh live runtime state from `ChatGPT_Termius/AFZ-PROJECT-EXECUTION-LATEST.json` when that OneDrive mirror is available

## Safety / rollback

- A request may force Commander with `force_route: "commander"`.
- Global rollback is one config edit: set `default_route` to `commander` in `project-execution-router.json`.
- Restore Hermes by setting `default_route` back to `hermes`.
- Commander fallback is automatic only when Hermes failed before execution began. If Hermes may have modified a worktree, the router stops for state review before any second executor is allowed to touch it.
- Hermes runs with checkpoints and without `--yolo`.
- Existing dirty worktrees are preserved by default; no reset/clean/force-push behavior is authorized by this router.

## Result contract

Every task should end with a portable result containing at least:

- request ID and resume key
- source SHA
- chosen route and worker
- project/worktree path
- pre/post Git HEAD, branch and status when available
- Hermes exit/status summary
- whether mutation may have started
- STATUS / VERIFIED / BLOCKER / NEXT

The windows-main router mirrors the latest sanitized runtime envelope to:

- `OneDrive -> ChatGPT_Termius -> AFZ-PROJECT-EXECUTION-LATEST.json`
- `OneDrive -> ChatGPT_Termius -> AFZ-OTHER-ACCOUNT-PROJECT-EXECUTION-LATEST.txt`

These mirrors are for continuation/diagnostics only.

## Continuation rule

Do not restart completed milestones merely because the chat/account changed. Read the current request/result, refresh live Git/worker state, then continue from the recorded `NEXT` action.
