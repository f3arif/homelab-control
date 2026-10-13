# Media fallback recovery checkpoint — 2026-10-13

This is a sanitized source checkpoint for an isolated qBittorrent, Radarr,
Prowlarr, and Seerr recovery stack. It is not a complete backup of application
databases, credentials, movie history, or request history.

All images are pinned to the digests used during recovery. The compose file
requires AFZ_FALLBACK_ROOT, an absolute appdata directory on the Linux host.
The LinuxServer containers use UID/GID 1000. Create their config directories,
downloads, and library-landing with ownership appropriate to that account.
Seerr also runs as UID 1000 and requires its config directory to be writable.

| Service | Local endpoint | Connection detail |
| --- | --- | --- |
| qBittorrent 5.2.4 | http://127.0.0.1:18796 | Internal Web UI port must also be 18796 |
| Radarr 6.4.4.10685 | http://127.0.0.1:18797 | Connect to qbittorrent:18796 on the bridge |
| Prowlarr 2.6.5.5623 | http://127.0.0.1:18798 | Sync to http://radarr:7878 on the bridge |
| Seerr 3.5.0 | http://127.0.0.1:18799 | Host network; HOST=127.0.0.1 limits its listener |

Seerr uses host networking to reach the existing native Jellyfin loopback
listener. Configure its Jellyfin server at http://127.0.0.1:8096 and its Radarr
server at 127.0.0.1:18797. These addresses refer to the host running the stack.

## What was verified

- qBittorrent authentication works with the installed 5.2 API, including
  HTTP 204 login responses and the port-specific session cookie.
- Radarr's qBittorrent connection test passed. Category: afz-fallback.
- Both download applications share /downloads. Radarr's isolated writable
  import root is /movies, backed by library-landing on the host.
- Three public indexers passed validation and synchronized through Prowlarr.
  A read-only search returned 92 results; it added no downloads.
- A bounded official Ubuntu torrent received 376,734 bytes from peers in
  16.22 seconds. The exact test torrent and its files were removed; queue
  count returned to zero.
- Private access routes were checked from a second machine. Existing routes
  and public publishing settings were preserved.
- Seerr could reach the native Jellyfin server after binding on host loopback.

## Setup and recovery notes

secure_qbit.py is for the new isolated instance only. It requires Python
requests, reads the temporary password locally, creates qbit-credentials.json
with mode 0600, and never prints the generated password. Existing credentials
are reused. Do not use it to reset an established user's configuration.

verify_transfer.py is the exact bounded connectivity procedure with its
appdata path replaced by AFZ_FALLBACK_ROOT. It requires an empty queue,
uses only an official Ubuntu torrent, and has a separate cleanup watchdog.
A completed receipt prevents accidental repeat runs.

Application configuration is intentionally absent from this public checkpoint.
The live Radarr client, root folder, Prowlarr application and indexers, and Seerr
service defaults reside in the private appdata directory. Preserve those
settings and databases separately. Never commit API keys, passwords, session
cookies, or private routing snapshots.

Seerr still requires its initial Jellyfin owner sign-in. The former application
API key was rejected, so no owner account or token was fabricated. Automatic
request integration remains pending that sign-in and its subsequent connection
checks. Existing application launchers and source-health guards were not changed.

Before enabling automatic requests, confirm the owner, selected libraries,
Radarr quality profiles (including separate 4K behavior if required), completed
download imports, and Jellyfin access to the isolated import directory. Keep
the existing media mounts read-only until their storage plan is explicitly
changed.

## Scope

The prior expired debrid service remained disabled. Existing media was not
deleted or moved. No movie download was added. This recovery did not restore
the old Radarr movie list or the former request database.
