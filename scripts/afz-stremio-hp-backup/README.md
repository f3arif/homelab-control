# AFZ Movies / Nuvio — HP Envy backup failover

Operational recovery bundle for the HP Envy warm standby of the AFZ Movies & TV Stremio backend.

## Runtime topology

- Primary: H3, AFZ Movies & TV v0.6.243.
- Backup: HP Envy, local backend on 127.0.0.1:18775.
- Backup manifest id: `com.afzengineering.releasecatalog.hpbackup`.
- Provider bridge: 127.0.0.1:18768.
- Tailnet backup route: HP Envy HTTPS :8445 -> 127.0.0.1:18775.
- Public backup transport uses the existing tokenized HP Envy Funnel route. The token is stored only on HP Envy in `private/public-transport-token.txt`; do not commit it.

The HP backup add-on is stream-only so it does not duplicate the primary AFZ home/catalog rows. While H3 is healthy the HP add-on returns zero streams. When the H3 health endpoint is unavailable or invalid, HP returns its provider-backed stream choices.

## Synchronization and durability

- `sync-from-h3.sh` runs every 15 minutes and copies the current H3 source, applies the HP standby patch, validates it with `py_compile`, refreshes the private add-on collection, and restarts only components whose inputs changed.
- `health-backup.sh` runs every 2 minutes. It self-heals the local backend and provider bridge and verifies both Tailscale routes.
- All three user services/timers are enabled with user linger, so they start without an interactive login.
- Runtime source/state backups are retained before updates.

## Verified 2026-09-30

- H3 raw source SHA-256: `1ce6be3459c00cb00f182ba6831965adab7a2f36217eb8430c9912cbd98e0315`.
- HP patched source SHA-256: `cb5854b6d5774ca862212cbc953d9536bf98c906c716c943d4036817a70a0caf`.
- Healthy-primary gate: HP backup returned 0 streams for test movie `tt36958312`.
- Failure canary with the primary health URL intentionally unreachable returned 13 streams, including Play Best, Auto 4K/1080p/TV/Mobile/Data Saver, TorBox, Real-Debrid, and Auto Download.
- Live H3-side request to the HP public backup transport returned the HP backup manifest and zero streams while H3 was healthy.
- H3 account add-on export contained exactly one HP backup add-on entry.
- Last manual sync check exited 0 and reported providerBridgeOk=true.

## HP-local hot mirror

A bounded local-media hot mirror is maintained on the HP Envy G-volume under:

`G:\AFZ-Backups\AFZ-Stremio\HotMirror`

The H3-side sync script `Sync-AFZ-Stremio-HotMirror.ps1` is additive only; it never purges destination media. Current policy copies all AFZ TV content plus the newest movie folders that fit within a 200 GiB movie budget. The first 2026-09-30 selection is about 231.6 GiB total, leaving roughly 85 GiB free on the HP G-volume at selection time.

Use `Test-AFZ-Stremio-HotMirror.ps1` after a sync to compare the destination byte totals to the saved selection manifest.

## Important limitation

HP Envy can keep online provider/debrid playback working when H3 is unavailable. Some AFZ local media still depends on H3-hosted storage/mounts, so a full H3 hardware/storage outage can make those local files unavailable even though the HP backend remains healthy. Move or replicate the media storage to HP-accessible independent storage before treating local-file playback as fully redundant.

Resume key: `AFZ-NUVIO-HP-BACKUP-FAILOVER-R1-20260930`.
