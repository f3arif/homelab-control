# AFZ Movies / Nuvio — HP Envy backup failover

Operational recovery bundle for the HP Envy warm standby of the AFZ Movies & TV Stremio backend.

## Runtime topology

- Primary: H3, AFZ Movies & TV v0.6.243 on `127.0.0.1:18774`.
- H3 tailnet health route: `http://100.106.186.118:18777` via Tailscale Serve to the H3 backend.
- Backup: HP Envy on `127.0.0.1:18775`.
- Backup manifest id: `com.afzengineering.releasecatalog.hpbackup`.
- Provider bridge: `127.0.0.1:18768`.
- HP tailnet route: HTTPS :8445 -> `127.0.0.1:18775`.
- Public backup transport uses the existing tokenized HP Envy Funnel route. The token remains only on HP.

The HP backup add-on is stream-only so it does not duplicate the primary AFZ home/catalog rows. While H3 is healthy, HP returns zero streams. When H3 health is unavailable or invalid, HP exposes its local hot-mirror copy plus online provider choices.

## Independent HP local-media mirror

The real independent mirror is stored on HP Envy at:

`/home/coolyo/afz-stremio-hotmirror`

It is populated from the existing read-only SSHFS mount of H3's `F:\Media` tree. The mirror currently contains:

- all selected TV content,
- a bounded newest-movie selection (200 GiB cap), rebuilt from the H3 tree on every sync run by `hotmirror.py select`,
- the generated selection manifest `config/selection.json`,
- sync status and logs.

`sync-hotmirror.sh` is additive and restart-safe. It uses `rsync --partial` and does not purge destination files. After each pass `hotmirror.py verify` checks that every source file of TV and of the selected movies exists in the mirror with the same size, and records movies that are still on disk but no longer selected as `unselectedPresent` in `state/status.json`. Movie copying stops (status `blocked`, `low-disk:<name>`) before free space would drop below 40 GiB (`AFZ_HOTMIRROR_RESERVE_BYTES`). `AFZ_HOTMIRROR_FREEZE_SELECTION=1` keeps the current selection unchanged and disables pruning (manual freeze/rollback control).

### Pruning

After a run has rebuilt the selection, copied everything it needs and passed per-file verification, `hotmirror.py verify --prune` removes mirror copies outside the active selection: whole movie folders no longer selected, and files inside selected folders that no longer exist on H3 (e.g. a replaced release). Pruning only touches `/home/coolyo/afz-stremio-hotmirror/Movies`; it never writes to the H3 mount. TV is never pruned.

It aborts without removing anything when any of these holds: the selection was not rebuilt in this run (refresh failed or frozen), verification failed, the manifest is inconsistent (schema, duplicate names, byte sum, cap), the H3 mount is not mounted or shares a device or path with the mirror, a selected movie is missing or empty on H3, the mirror contains a symlink or a non-directory entry, more than 10 folders (`AFZ_HOTMIRROR_PRUNE_MAX_DIRS`) or more than the cap would be removed. A run blocked by low disk, a lost mount or an rsync failure never reaches pruning, so the 40 GiB reserve rule is unchanged.

Removals are staged by rename under `.prune-staging/` on the mirror filesystem, then deleted. Every plan, removed file (path and bytes), abort and error is appended as JSON lines to `logs/prune.log`; the outcome is also in `state/status.json` under `prune`. An error during removal stops immediately and exits 31. `AFZ_HOTMIRROR_PRUNE=0` disables pruning alone.

The sync timer runs every six hours and is persistent across reboots.

## Standby behavior

`apply-hp-standby.py` patches the current H3 source into an HP standby build. Primary health uses the direct tailnet route plus the expected Host header, avoiding dependence on HP MagicDNS behavior.

When H3 is healthy:
- HP manifest stays available.
- HP stream endpoints return zero streams.

When H3 is unavailable:
- HP local mirror entries are returned as `AFZ Local`.
- local files are served directly from HP.
- provider-backed TorBox / Real-Debrid / Comet / Torrentio choices remain available.

## Synchronization and health

- `sync-from-h3.sh`: source/add-on sync from H3 every 15 minutes.
- `health-backup.sh`: HP backend/provider/route health every 2 minutes. Its `status` covers serving only; the hot mirror is reported separately as `hotMirror` (status, age, prune result, free space) and `warnings` (`hotmirror:<status>`, `hotmirror:stale:<h>` after 13h without a run, `hotmirror:prune:aborted…`, `hotmirror:below-reserve`, `hotmirror:status-unreadable`) in `state/hp-backup-health.json`.
- `sync-hotmirror.sh`: independent media mirror refresh every 6 hours.
- All user services/timers run with user linger enabled.

## Verified 2026-10-01

- H3 raw source SHA-256: `1ce6be3459c00cb00f182ba6831965adab7a2f36217eb8430c9912cbd98e0315`.
- HP patched source SHA-256: `29e47512e60081f84750b3ad938da3bfd1964688416466dc240a3130b6159523`.
- HP mirror verification:
  - TV bytes: `35471630390`
  - movie bytes: `213158677995`
  - selected movies: 31
  - missing items: none
- Healthy-primary gate: HP returned 0 streams.
- Isolated H3-unavailable canary for `tt28014327` returned:
  - AFZ Local
  - provider-backed alternatives
  - successful HTTP range response `206`
  - first 1 MiB served directly from the HP mirror.

## Install and verify

`install.sh` copies this bundle to the deployed paths on HP (`run-backup.sh`, `sync-from-h3.sh`, `apply-hp-standby.py` and `bin/health-backup.sh` under `afz-stremio-secondhost-20260918`; `sync.sh` and `verify/` under `afz-stremio-hotmirror`; units under `~/.config/systemd/user`). Changed files are backed up as `*.before-install-<stamp>.bak`; unchanged files are skipped. `install.sh --enable` also reloads systemd and enables the services and timers.

- `python3 verify/prod-verify.py`: healthy-primary gate, expects `HEALTHY_GATE_STREAMS 0` while H3 is up.
- `bash verify/canary.sh`: starts an isolated H3-unavailable canary on `127.0.0.1:18776`, requires an `AFZ Local` stream plus a 1 MiB `206` range fetch from the mirror, prints `AFZ_HP_CANARY_OK`, then stops the canary. Production on 18775 is not touched.

## Hardening R3 (2026-10-01)

- Health check derives the expected version from the deployed `stremio_catalog.py` instead of a hard-coded `0.6.243`, so an H3 version bump no longer causes a restart loop on HP.
- H3 primary is considered healthy on manifest id alone; version skew during the 15-minute sync window no longer makes HP serve duplicate streams.
- Hot-mirror movie rsync failures now fail the sync (exit 21, `movie-rsync:<name>`) instead of being swallowed inside a pipe subshell.
- `sync-from-h3.sh` waits up to 45s for a restarted backend before probing it, instead of failing the unit after a fixed 2s.
- The mirror selection is rebuilt each run instead of being frozen at its 2026-10-01 snapshot, and verification is per file instead of against frozen byte totals (which would have failed every run after H3 gained any TV episode).
- Deployed 2026-10-01 21:50Z. HP patched source SHA-256 is now `fbfdced81f8402f4572fff34546f24cd24ce3dd66a54fe60f68642c83a6745ab` (same H3 raw source). Healthy gate returned 0 streams; isolated canary returned `AFZ Local` with a `206` 1 MiB range read.

## Recovery

If HP is rebuilt:
1. restore this directory from GitHub,
2. restore the private transport token, addon collection, `bridge.mjs` and the Python venv separately,
3. run `bash install.sh --enable`,
4. run `python3 /home/coolyo/afz-stremio-hotmirror/hotmirror.py select /home/coolyo/afz-jellyfin-primary/mounts/afz-media /home/coolyo/afz-stremio-hotmirror/config/selection.json` once the H3 media mount is up (the sync also does this itself),
5. confirm the sync and health timers are listed in `systemctl --user list-timers`,
6. run `python3 verify/prod-verify.py` and `bash verify/canary.sh`.

Resume key: `AFZ-NUVIO-HP-HARDENING-R3-20261001`.
