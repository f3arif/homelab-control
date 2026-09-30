# AFZ chat-timeout recovery: single-host pilot

The chat is the control surface, not the job's parent process. Submit a reviewed
script once, preserve its job ID, and inspect that same ID after a disconnection.
`resume` is deliberately read-only and never executes a script.

## Scope and safety

This helper uses an existing Linux systemd user manager. It adds no polling queue,
permanent daemon, scheduled automation, production restart policy or exposed port.
The source is in `f3arif/homelab-control`, on the feature branch
`feat/chat-timeout-safe-jobs-20260930`; this pilot is not a merge to main.

It snapshots the submitted script and runner, records the script SHA-256, uses a
single-host project lock, and writes private durable state and evidence references.
The same ID cannot launch another copy, including after success, failure, a timeout
or an uncertain outcome. Different inputs with the same ID are rejected.

A `read-only` label is a declaration, NOT a sandbox. Review every script before
submission. Local changes need explicit authorization and the acknowledgement
flag. Sending, publishing, deleting, making purchases and other consequential
external actions still require the user's specific confirmation; this helper does
not provide that permission. Do not put credentials in scripts, command lines,
Git commits or shared logs. Load secrets from an existing protected local source.

Only jobs launched through this helper get its protections. Its lock does not
coordinate with existing Control Hub jobs, other chats, Windows tasks, H3 or
application-specific writers. Verify those separately. A dropped connection is
not proof that a host stopped; do not start a failover writer without fencing.

## Submit once

After installing a pinned, SHA-verified copy, the pilot launcher is:

```bash
~/bin/afz-job submit project-step-unique-id \
  --project project-name --script /absolute/path/reviewed-step.sh \
  --timeout 1800 --effect read-only
~/bin/afz-job status project-step-unique-id
~/bin/afz-job resume project-step-unique-id
```

Use a stable ID for the intended operation, not a fresh timestamp each time the
chat reconnects. A new ID is a new action and must follow reconciliation and any
needed authorization. Do not remove job directories or reset their state to retry.

Scripts execute as the current user, without an interactive terminal. They must
not prompt for credentials. By default their working directory is the user's home;
use `--cwd` explicitly when required. The script is a snapshot, so use absolute
paths for dependencies and separately pin/check those dependencies.

## Meaningful checkpoints inside a script

Split changes into ACTION then VERIFY. After obtaining real evidence, save it
under a new filename in `$AFZ_JOB_DIR`, then record a checkpoint:

```bash
python3 "$AFZ_JOB_DIR/runner.py" --root "$AFZ_JOB_ROOT" \
  checkpoint "$AFZ_JOB_ID" --phase verified-step-name \
  --next-step "Read live state before the next action" \
  --evidence "$AFZ_JOB_DIR/step-evidence.json"
```

The evidence hash is saved with the phase and next step. The helper records the
caller's observation; it does not certify that an application's state is correct.
Never mark an operation completed merely because its tool call returned.

## After a timeout

1. Reconnect or start a fresh chat with the existing job ID and resume key.
2. Read `resume`, saved evidence, logs and the application's current state.
3. Leave a still-running job alone. Never replay an uncertain external operation.
4. Reconcile missing outcomes; only then authorize a separately identified next step.

`COMPLETED` means the submitted script exited with zero, not that an application
is healthy, audio played, a publication happened or a restore was correct.
`VERIFY_REQUIRED` and `UNKNOWN_VERIFY_FIRST` require reconciliation.
`BLOCKED` does not queue a retry. `FAILED` also does not retry automatically.

The unit uses `Restart=no`. A chat/terminal disconnect does not intentionally stop
it. A host shutdown, reboot, user-manager failure, script error or runtime limit
can still stop work. Runtime state remains on disk, but jobs do not automatically
re-execute after reboot. systemd collects finished transient units, while this
helper retains job directories. Do not use a PID alone as proof of ownership.

## Runtime layout

`~/.local/state/afz-safe-jobs/<job-id>/` contains:
`manifest.json`, `launch.json`, `state.json`, `checkpoint.json` when supplied,
`payload.sh`, `runner.py`, `job.log` and job-specific evidence.
This private runtime data must not be committed to a public repository.

The initial Radio Hilal probe performs only local HTTP GETs, Docker inspect and
Supervisor status. It does not restart, migrate, import or publish anything.
An online API is not proof that station audio is playable.

## Tests and removal

Run `python3 -m unittest -v test_afz_safe_job` in this directory. The 16 tests cover
private atomic state, stable IDs, input changes, duplicate and stale execution,
project locks, script integrity, failure, timeout and missing manager/unit states.
Also validate a harmless detached canary and duplicate submissions on the target
host; local unit tests alone are not proof of systemd integration.

Rollback consists of ceasing submissions and removing the new launcher/code only
after checking for active units. Preserve job records and logs for recovery. Do
not stop unrelated services or clear existing Control Hub queues.
