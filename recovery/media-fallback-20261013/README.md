# Media fallback recovery checkpoint — 2026-10-13

This directory contains sanitized recovery source for qBittorrent, Radarr,
Sonarr, Prowlarr and Seerr. Private databases, API keys, passwords, media and
connection files are deliberately excluded.

The original Windows-main SSD configuration has been restored into the Linux
stack. Requests retains 3 accounts and 63 original requests. Radarr has the
56-movie catalog and historical records. Sonarr has the original 3 series.
Jellyfin storage paths and automatic detection for the writable landing areas
have been repaired.

## Runtime

All five container images are pinned to the recovery digests. Set
AFZ_FALLBACK_ROOT to the absolute Linux appdata root and AFZ_JELLYFIN_ROOT to
the existing native Jellyfin directory before using compose. LinuxServer
containers and Seerr use UID/GID 1000; preserve the established ownership.

| Service | Local endpoint | Connection |
| --- | --- | --- |
| qBittorrent 5.2.4 | http://127.0.0.1:18796 | Internal Web UI port 18796 |
| Radarr 6.4.4.10685 | http://127.0.0.1:18797 | qbittorrent:18796; category afz-fallback |
| Sonarr 4.0.20.3014 | http://127.0.0.1:18801 | qbittorrent:18796; category afz-tv-fallback |
| Prowlarr 2.6.5.5623 | http://127.0.0.1:18798 | radarr:7878 and sonarr:8989 |
| Seerr 3.5.0 | http://127.0.0.1:18799 | Host network, HOST=127.0.0.1 |

Seerr reaches native Jellyfin at 127.0.0.1:8096, Radarr at 127.0.0.1:18797 and
Sonarr at 127.0.0.1:18801. Its restored default roots are /movies and /tv,
with HD-1080p profile 4. Availability sync is enabled for both applications.
For Seerr settings updates, omit the read-only id field from the PUT body.

## Restored media and paths

- Radarr retains 56 movie records and 190 historical records. Reconciliation
  found 46 existing movie files. Their archive paths use /legacy-media and
  remain read-only and unmonitored. The other 10 records use writable /movies.
- Radarr mounts the existing Jellyfin mounts parent at /legacy-media:ro.
  Its UID 1000 can read the existing owner-only SSHFS mounts. No allow_other,
  write access, SSHFS permissions or host mount propagation was introduced.
- The mount parent uses private Docker propagation. If the native supervisor
  recreates SSHFS mounts, recreate Radarr after the mounts are ready so it
  sees the renewed mount instances.
- Sonarr retains the original 3 series, profiles and history. All 46 recorded
  files were present; a further 16 videos were found. The 62 videos, totaling
  35,471,630,390 bytes, were copied into library-landing-tv and verified by
  exact file sizes. All source files and original mounts remain unchanged.
- Sonarr's /episodefile API confirms 13, 30 and 19 distinct files for the
  respective series. Its statistics count 110 episode associations because
  some videos contain multiple episodes; that is not 110 physical files.
- Jellyfin keeps the original accounts and library IDs. All 22 stale Windows
  shortcuts were repaired. TV Shows now uses library-landing-tv; AFZ Downloads
  uses library-landing. Both writable landing libraries monitor changes.
- Keep AFZ-Library-Directory.txt in the movie landing directory so an empty
  root remains discoverable during Jellyfin top-level scans.

Original Windows-main appdata was only read. Private normalized SQLite backups
passed quick_check. Seerr's original user IDs matched the current Jellyfin users;
no owner replacement or password reset was needed.

## Verification

- qBittorrent authentication passes with the installed 5.2 API, including
  HTTP 204 login responses and its port-specific session cookie.
- Radarr and Sonarr qBittorrent tests passed. Their shared /downloads and
  writable library roots are accessible.
- Prowlarr has 3 validated movie sources and synchronizes 2 TV-capable sources
  to Sonarr. All 3 Radarr indexer tests passed again after catalog activation.
- The earlier bounded official Ubuntu test received 376,734 bytes from peers
  in 16.22 seconds. Its torrent and files were removed. Do not repeat it
  without a concrete new reason.
- A unique, locally generated movie clip was detected automatically by
  Jellyfin in 65 seconds. An HTTP 206 byte-range request matched the file.
  The generated test files were removed.
- Jellyfin sees 46 archive movies and 62 TV videos. A copied TV video's
  byte-range playback check returned HTTP 206.
- H3 can reach Requests and Radarr. It sees the restored Sonarr connector
  through Requests. Core source and its source-health guard are unchanged.
- A restored monitored movie request resumed automatically, downloaded and
  imported all 11,627,943,029 bytes, and continued seeding. At 21:18:21 UTC,
  Radarr reported hasFile=true and the full file size. Jellyfin served the
  final 1,024 bytes with HTTP 206, matching the completed file exactly.
  This verified an existing request through download, import and a playback
  byte-range check; no new movie was selected as a test.

The separate /downloads and /movies bind mounts caused the import hardlink to
fail and Radarr fell back to a copy. The copy finished without interruption.
observe_completed_movie_import.py is a bounded, read-only observer for an
existing import. This run finished successfully and exited. Its private receipt
records importComplete=true and playbackVerified=true. No repeat is needed.

## H3 direct TV connection verified

The user approved the SSH alternative on 2026-10-13 after the new Tailscale
Serve route was denied. The existing Tailscale permissions and routes were
preserved. No public listener was added.

The Envy user service afz-sonarr-h3-tunnel.service is active and enabled.
It uses the established SSH identity, strict host-key verification, keepalives
and automatic restart. Existing user lingering was already enabled, so this
runs independently of the chat and interactive login.

The forwarded listener was verified as H3 127.0.0.1:18801 only. Authenticated
Sonarr status, all 3 series and the TV queue returned HTTP 200. H3's launcher
now uses SONARR_URL=http://127.0.0.1:18801/api/v3.

At 21:35 UTC, H3's own system-health endpoint reported Radarr, Sonarr,
Jellyfin and the Stremio bridge healthy. The TV queue was readable, qBittorrent
remained ready, and Radarr/qBittorrent remained the selected download route.
The existing core and all source-health guard files retained their hashes.
The scheduled task completed with result 0 after the launcher update.

The service template contains placeholders for the private SSH key path and
target; substitute verified values before installation. Activate-H3-Sonarr.ps1
requires a recovery directory, checks the exact approved source hashes and
loopback listener, preserves a launcher backup, and rolls back if the changed
connection or existing routing fails verification. It is an activation record,
not a script to rerun against a later deployment without a fresh preflight.

The H3 launcher already reads the private Requests/Radarr connection file and
uses STREMIO_RADARR_DIRECT_ROOT=/movies. Keep the expired Real-Debrid service
disabled. Preserve the current core and source-health guard as a matched pair;
the later Nuvio landing repair below supersedes their connection-only hashes.

## Recovery procedures and private backups

These scripts are one-time recovery tools, not recurring jobs. Read the code
and preserve current appdata before running any activation again.

- AFZ_FALLBACK_ROOT: existing Linux stack appdata root.
- AFZ_JELLYFIN_ROOT: native Jellyfin directory containing mounts/.
- AFZ_REQUESTS_RECOVERY_DIR: private recovery directory containing original/.
- AFZ_REQUESTS_PUBLIC_URL, AFZ_RADARR_PUBLIC_URL, AFZ_JELLYFIN_PUBLIC_URL:
  existing private application URLs used by the preflight.
- AFZ_H3_CORE_ROOT: Windows application directory.
- AFZ_VERIFY_MOVIE_ID: already existing Radarr movie ID for the read-only observer.

secure_qbit.py is for the isolated recovery instance and reuses established
credentials. Do not use it to reset an unrelated installation.
verify_transfer.py requires an empty queue and an explicit reason to rerun.
prepare_sonarr_restore.py needs the original normalized Sonarr data and current
Radarr account table; configure_sonarr_restore.py connects the running service.

Preserve the private source exports, consistent SQLite backups, pre-activation
Radarr/Seerr directories, Jellyfin database/config backup and H3 launcher
backup. They contain secrets and must not enter Git. Rollback must retain any
user changes and downloads made after the checkpoint.

The Jellyfin key was valid throughout. Jellyfin 12 rejects the deprecated
X-Emby-Token header; use Authorization: MediaBrowser with the existing key.
Seerr 3.5.0 already uses that header. Official change:
https://github.com/jellyfin/jellyfin/pull/15559

This recovery branch has not been merged into main. The existing dirty H3 Git
checkout was not modified.


## Nuvio Envy landing playback repaired

At 22:08 UTC, the newly imported movie was added to the existing Ready to Watch
catalog and offered through the existing AFZ Jellyfin proxy. The previous core
required every Jellyfin movie to have a corresponding H3 filesystem path,
which excluded movies stored only in Envy's writable movie landing folder.
The new code explicitly opts into that one configured folder using
AFZ_HP_JELLYFIN_MOVIE_ROOT. It accepts only file-backed Movie metadata, rejects
remote sources, placeholders, invalid IDs and traversal paths, and verifies an
authenticated one-byte HTTP 206 response with the expected full file size.
The source stays pinned to its exact Jellyfin item ID. Availability probes are
cached for 60 seconds and fail closed. Existing H3 movie and TV paths remain.

The core, launcher and guard pin were updated together while holding the
existing guard mutex. The guard's integrity check and rollback policy remain
active; healthy_streams.py and its tests were unchanged. No Tailscale routes,
media files, credentials, download queues or original SSD appdata were changed.
The core's manifest version remains 0.6.243 for the existing launcher contract.

Verification: nine boundary/outage unit tests passed. An isolated candidate
check preserved all 24 existing movie cards and added the Envy movie. Live
validation through the public Nuvio URL and health-v3 sorter returned the new
AFZ Jellyfin source. Its 1,024-byte HTTP 206 response matched the candidate
exactly. One restored episode from each of the three TV series also returned
1,024 bytes with HTTP 206 through its public local-playback route. Overall
system health was true. This verifies bounded playback delivery, not full-film
viewing or phone codec compatibility. No new requests or torrents were created.

Files:
- prepare_nuvio_landing_playback.py prepares candidates only; it checks the
  inspected prior hashes and never edits live files.
- test_nuvio_landing_playback.py contains the nine isolated tests.
- verify_nuvio_landing_candidate.py loads only selected candidate AST functions
  and tests one existing file without starting the application.
- Activate-Nuvio-Landing.ps1 installs the matched candidate files, keeps backups
  and restores the prior files if live verification fails.
- verify_nuvio_landing_live.py verifies catalog inclusion, the public source
  sorter, movie playback and the three restored TV playback paths.

The activation is complete; do not rerun it against newer files. Its private
candidate folder holds prepared.json, candidate-verification.json,
live-verification.json, activation.json and before-activation backups.
Current hashes:
- core: eaea71d7be0ffd3a78650602ee010b2360406bb95486fac286f8f9acefe56b59
- launcher: 9e1a7a77d4eaaba2e825ddfe9f719f94bb565f82c0c68e78a4dc5cd0e729cc8f
- guard: 6b9d1d999bf3b4211e21d73d42e4b6b71cb203e076ff6d44a8c7ac4b5b28f16a

The restored TV series use the existing H3 local files in Nuvio; Envy's copied
TV files remain playable in Jellyfin. This movie-only repair does not add a
remote Nuvio path for future TV episodes that exist only on Envy.
