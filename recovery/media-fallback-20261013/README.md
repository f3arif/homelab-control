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

## H3 direct TV connection remains pending

TV Requests can use the restored Seerr-to-Sonarr connector. H3's direct Sonarr
status/queue URL remains disabled. Creating a new Tailscale Serve route was
rejected with 401 Unauthorized because the current account is not an approved
operator for that change. No route or privilege setting was changed.

A loopback-only SSH reverse tunnel has been prepared privately but has not
been installed or enabled. Approval for this alternative is required before
connecting H3's direct TV status/queue functions. No public exposure is planned.

The H3 launcher already reads the private Requests/Radarr connection file and
uses STREMIO_RADARR_DIRECT_ROOT=/movies. Preserve the core source and existing
source-health guard. Keep the expired Real-Debrid service disabled.

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

