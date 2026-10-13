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

The original Windows-main Jellyseerr configuration was recovered from its
attached SSD on 2026-10-13. A hash-verified copy retained SQLite WAL content,
and both recovered databases passed quick_check before any application change.
Seerr is now initialized with the original owner, 3 account records, 63 requests,
and 85 media records. The original account IDs match the current Jellyfin users.
No account or password reset was needed.

Correction to the initial checkpoint: the saved Jellyfin API key was valid.
Jellyfin 12 rejected the deprecated X-Emby-Token header. The standard
Authorization: MediaBrowser header authenticated successfully. Seerr 3.5.0
already uses that header. See the official Jellyfin change:
https://github.com/jellyfin/jellyfin/pull/15559

The H3 launcher now reads the private Requests/Radarr connection file from
state/media-requests-connection.json, with STREMIO_RADARR_DIRECT_ROOT=/movies.
The live /download-routing.json reports qBittorrent ready and selects
Radarr/qBittorrent. The core source hash and source-health guard are unchanged.
The original custom Radarr profile 7, "1080p + 4K", was restored through the API.

The restored Requests API, owner, request count, Jellyfin user connection,
Radarr/qBittorrent connection test, and H3 routing were verified. The torrent
queue remained empty. A complete new movie request, transfer, import and
playback has not been exercised.

The old Radarr database contains 56 movies and is retained as a verified private
backup; that catalog has not replaced the new live Radarr database. The old
Sonarr connector is archived because no replacement Sonarr service is running.
Jellyfin still contains legacy Windows media paths. An isolated AFZ Downloads
library was registered against library-landing, but its collection ID was not
assigned at verification time. Resolve that library registration and storage
mapping before claiming completed imports/playback. Avoid a broad scan of the
unmapped legacy libraries. Existing media mounts remain read-only.

## Scope

The prior expired debrid service remained disabled. Existing media was not
deleted or moved. No movie download was added. This recovery did not restore
the old Radarr movie list. The former request database has been restored.

## Recovery scripts

The scripts in this directory preserve the export, preflight, activation and
launcher-update procedures. Their deployment-specific paths were replaced by
environment variables or explicit parameters. They are one-time recovery tools,
not recurring jobs. Read the code and set the required paths before running.
The original SSD is only read by export_windows_main_requests.py. Keep all
exports, databases and connection files private and out of Git.

- AFZ_FALLBACK_ROOT: existing Linux stack appdata root.
- AFZ_REQUESTS_RECOVERY_DIR: private recovery directory containing original/.
- AFZ_REQUESTS_PUBLIC_URL, AFZ_RADARR_PUBLIC_URL, AFZ_JELLYFIN_PUBLIC_URL:
  existing private application URLs used during preflight.
- AFZ_H3_CORE_ROOT: Windows app directory (defaults to the established path).

activate_requests_restore.py restores the previous Seerr directory if its
owner and request-count checks do not pass. The H3 activation script similarly
restores its launcher backup if routing does not become ready. Preserve these
backups and avoid overwriting changes made after the checkpoint.
