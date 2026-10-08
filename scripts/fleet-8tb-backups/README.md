# Additional Pi and HP backups on the H3 media drive

These helpers add backup copies on an explicitly identified Windows media
volume. Profiles, recovery credentials and operational receipts remain private
on the deployment host. Source code is the reusable part of this directory.

## Backup paths and completion rules

`backup_pi.py PRIVATE_PROFILE` copies an existing encrypted restic repository
without reading its password. It observes the known writer services and boot
identity before and after a capture, requires empty repository locks, compares
full source manifests, and checks the staged bytes. `observe_units.py` supplies
the stable systemd observation over the already configured SSH connection.

The Pi stage goes to a new `.partial` generation. The receiver then verifies
every file's size and SHA-256 and the exact directory layout. It rejects reparse
points and checks the target volume before publishing the generation and
atomically replacing `latest.json`. Previous remote generations are retained.
Unchanged-source checks also verify the existing destination generation.

Repeated publication uses `[IO.File]::Replace` with `[NullString]::Value` for
the optional backup filename. Windows PowerShell can coerce an ordinary `$null`
argument to an empty string here, causing replacement of an existing pointer
to fail. The explicit null string preserves the intended .NET call. A failed
replacement must leave the previous pointer unchanged; first publication and
replacement of an existing pointer both need the Windows regression below.

This is a **stable observed capture**, without an exclusive writer lock. It
does not claim to cover unknown writers or to decrypt or restore the repository.
Recovery still needs the existing restic password. Only generations with a
valid `COMPLETE`, no `INCOMPLETE`, and a verified publication receipt qualify.

`backup_hp.py PRIVATE_PROFILE` appends an encrypted application backup using an
official restic image pinned by digest. It runs as UID/GID 1000, mounts only the
individually configured source roots, avoids remote mounts, and reports
unreadable sources. It supplies an explicit scanned file list to restic.
Private SSH keys are excluded by filename and header; existing transport keys
are used in place. A minimal generated container account allows OpenSSH to run
under UID 1000 without reading or changing host account files.

Configured MariaDB/PostgreSQL exports use the existing database containers.
SQLite files are exported through the SQLite backup API and checked with
`quick_check`; raw live database and sidecar files are excluded. Empty directory
metadata and the exact coverage/exclusion list are recorded in the export
manifest. Live applications are not stopped, so this is not a simultaneous
snapshot across all services or a full machine image.

An HP run succeeds only after the snapshot is readable, repository checks pass,
and the final target-volume guard passes. Each run retains its own receipt;
`latest-success.json` is replaced only on success. Failed stages remain for
review. No new pruning or remote retention deletion is implemented.

If an earlier HP backup still holds the writer lock, a scheduled backup returns
`status: skipped_busy` and leaves that writer running. This scheduling no-op
does not create a success receipt or change the last verified snapshot.
Initialization still fails on lock contention.

### Rotating local staging and incomplete snapshots

An explicit file list can outlive a producer's local retention window during a
large initial backup. If the producer deletes a selected archive before restic
reads it, restic can save a snapshot and still return exit status 3. The runner
treats that as failure: it does not publish success or skip the missing-source
error. A saved snapshot ID alone is not a completed backup receipt.

Resolve a demonstrated staging race through narrow, documented profile
exclusions only after verifying the files' producer, retention policy, and
alternate recovery coverage. In the inspected Nextcloud workflow, local
non-latest staging files were removed by a `find -mtime +2` sweep. The
destination was configured for thirty days of history, and the two missing
files were verified there. The dated configuration export can also be
affected because its file modification time may precede its export filename.

The relevant filename families, relative to that verified staging directory,
are `nextcloud-[0-9]*.sql.gz`, `state-[0-9]*.json`, and `config-[0-9]*.php`.
Profiles use explicit absolute patterns scoped to the verified directory.
Retain every `latest` file, current configuration, operational receipt, backup
script, and the fresh native SQL export created for each HP run. Do not exclude
an entire backup directory merely because it contains rotating archives; it
may also contain unique configuration or recovery material.

Record the alternate coverage and exclusion reason in the private profile.
Preserve exit-status-3 failure for every other unreadable or vanished source.
A snapshot created by the earlier failed run retains that qualification. A new
run under the corrected scope must pass the normal snapshot, repository,
final-volume, and requested restore-probe checks before success is published.

### Existing Nextcloud transport

The existing HP Nextcloud backup created local database exports but could not
reach its H3 SFTP destination from Docker's bridge network. A read-only test
using the same credentials and image succeeded with host networking.

`patch_nextcloud.py` makes the bounded transport repair and inserts
`guard_volume.py` before backup work and before publishing the success marker.
The guard uses the existing SSH identity with strict host-key verification to
query Windows volume metadata, then requires the configured drive letter,
volume label, stable volume GUID and free-space reserve. An unavailable or
different drive causes failure. Existing backup paths and retention remain
under the established script's control.

Runtime profiles stay private on the deployment host. Public code and tests
contain no deployment addresses, MACs, credential values or user files. The
existing SSH private keys are used in place and are not copied to another host.

## Checks

```sh
python3 -m unittest discover -v
python3 -m unittest discover -s scheduling -v
```

The tests cover target identity and space checks, exact repair scope, source
changes and lock detection, stage/receiver hash checks, publication gating,
permission failures, committed SQLite WAL data, private-key omissions,
scoped cleanup after interrupted transfers, restore-marker comparison, private
password recovery, and valid persistent schedules. The receiver also needs a
read-only status preflight and an actual SFTP transfer on Windows.

The actual receiver publication block also has a Windows filesystem regression:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\test_backup_pi_publish.ps1 -TestRoot APPROVED_TEST_DIRECTORY
```

It uses a fresh test subdirectory to exercise first publication, repeated
publication, and a locked-target failure that must preserve the previous
pointer. The Python suite invokes this regression only on Windows; a skipped
test on Linux does not validate Windows PowerShell replacement semantics.

## Credentials and first HP backup

`escrow_password.py --profile PRIVATE_PROFILE` creates a private random password
only when absent, then sends it over verified SSH stdin to a Windows user-DPAPI
escrow. It verifies decryption and never replaces a different existing password
or escrow. The password is never a command argument or log field. DPAPI recovery
requires the original Windows user profile and its DPAPI keys; the media drive
and escrow file alone are not enough after losing that profile.

Run the read-only source plan and resolve its reported scope before the initial
backup. Repository creation is always explicit and requires
`new_repository: true` in the private profile:

```sh
python3 backup_hp.py PRIVATE_PROFILE --plan
python3 escrow_password.py --profile PRIVATE_PROFILE
python3 backup_hp.py PRIVATE_PROFILE --init
python3 backup_hp.py PRIVATE_PROFILE --verify-restore
```

Initialization is never a fallback for an authentication, network or repository
error. A restore probe reconstructs and compares one generated nonsecret file;
it does not establish a complete application restoration. `--check-data` reads
all repository data during the post-backup check when that validation is needed.

## Recurring schedules

The generator in `scheduling/make_user_units.py` renders four new user units;
it does not install or enable them. Run it with absolute deployment, HP profile,
Pi profile, and new output-directory paths. Before enabling the timers, verify
the target identity, credentials, source scope, explicit repository setup, and
the live overlap behavior. Once those prerequisites pass, a timer may be
enabled while the first manual backup is still running: its whole-run lock
keeps that run as the sole writer, and an overlapping scheduled invocation
returns `skipped_busy` without creating a success receipt. Confirm actual
backup completion separately from timer activation or a successful busy skip.

| Backup | Default calendar | Time basis | Service limit |
| --- | --- | --- | --- |
| HP applications | Daily 04:15 | Host's configured timezone | 12 hours |
| Pi repository | Hourly at :40, plus up to 180 seconds jitter | Host's configured timezone | 90 minutes |

Both timers use `Persistent=true`; each runner holds its own whole-run lock.
The user service manager must run after logout and boot, for example through
an already enabled lingering user session. Recurring commands append backups;
they never initialize repositories or delete old remote generations.

## Deployment

Verify the inspected source SHA-256, save original bytes and modes, stage the
new source, check shell syntax, and run the volume guard before replacement.
If a previous transfer is stuck in a bridge-network client, stop only that
identified backup client and allow the existing wrapper to release its lock.
Start the repaired wrapper, then verify fresh destination data and its success
marker. Preserve the existing backup schedule. Rollback restores the saved
wrapper and its mode.
