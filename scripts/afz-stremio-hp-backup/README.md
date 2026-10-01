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
- a bounded newest-movie selection,
- a generated selection manifest,
- sync status and logs.

`sync-hotmirror.sh` is additive and restart-safe. It uses `rsync --partial`, does not purge destination files, and validates byte totals after each completed pass.

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
- `health-backup.sh`: HP backend/provider/route health every 2 minutes.
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

## Recovery

If HP is rebuilt:
1. restore this directory from GitHub,
2. restore the private transport token, addon collection, `bridge.mjs` and the Python venv separately,
3. run `bash install.sh --enable`,
4. restore/generate `/home/coolyo/afz-stremio-hotmirror/config/selection.json`,
5. confirm the sync and health timers are listed in `systemctl --user list-timers`,
6. run `python3 verify/prod-verify.py` and `bash verify/canary.sh`.

Resume key: `AFZ-NUVIO-HP-HARDENING-R3-20261001`.
