# AFZ Movie Night → Nuvio: private, automatically refreshed ready movies

**Status: LIVE on HP Envy owner-only access gateway (2026-10-27 Toronto / 2026-10-28 UTC).** This is a separate Stremio-compatible Movie Night addon. It does not overwrite the existing `AFZ Movies & TV` addon, modify Nuvio APKs, change the ZBook review backend, or publish owner selections on public/general catalog endpoints.

## Install / subscribe once

- Manifest: `https://hpenvy.tailc9bb62.ts.net:8453/movie-night/manifest.json`
- Android deep link (Nuvio preview supports this scheme): `stremio://hpenvy.tailc9bb62.ts.net:8453/movie-night/manifest.json`
- On a phone/TV with the **owner's authorized Tailscale session connected**, open Nuvio → Add-ons → Add addon, paste the HTTPS manifest URL and install. Use the **primary, owner-authorized profile**. The deep link can start this install on supported Android Nuvio builds.
- The new home catalog is named **Movie Night · Ready on Server**. New Nuvio catalogs are enabled by default in the verified AFZ preview client source; if it is farther down Home, reorder in Home Catalog Settings. Reload Home after the first install.
- **Only one install per Nuvio profile/device is needed.** On each later catalog refresh, the service reads live ready-file state rather than copying a list. Some client builds hold a local Home cache; reopening Home or refreshing the catalog may be required to see a new file.

The manifest URL is **not** public access: the existing 8453 Tailscale Serve gateway still verifies the **exact owner account** on every manifest/catalog/meta/stream/poster/file request. Never embed owner secrets or a Tailscale-User-Login header in an APK. If a device cannot reach this owner-private address, do not enable the feed through a global public proxy.

## How synchronization works

`Movie Night finalized picks → bounded cached-only 1080p 5–15 GB transfer → checked/indexed file on ZBook 8 TB → MediaIndex.metas() → private Unix review relay → HP Envy 8453 owner-only Nuvio addon → Nuvio Home row / stream`

The source of truth is the existing authenticated ZBook `/movie-night/catalog/movie/downloaded.json`, backed by MediaIndex. It exposes **only entries with an indexed, visible file that still exists and matches the recorded size** (including a preserved historical completion below the newer 5 GB minimum). Pending picks, queued transfers, unavailable/failed files and unverified items never receive a playable addon row. The addon cannot enqueue a job or modify a user's choices.

The addon requests the private index afresh for catalog, metadata, and stream discovery, advertises `cacheMaxAge:0` and `no-store`, and rejects any malformed or temporarily unavailable source with 503 rather than claiming an empty successful catalog. Nuvio may still apply its own client-side caching. Downloaded files remain listed while they remain valid and indexed even if the user later changes their shortlist; changing a pick does not delete a completed file.

### Stremio resources

- `GET /movie-night/manifest.json` — new owner-private addon `com.afzengineering.movienight.ready`.
- `GET /movie-night/catalog/movie/afz_movie_night_ready.json` — ready movies, validated by the live index; optional `/skip=N.json`, 40 entries/page.
- `GET /movie-night/meta/movie/tt1234567.json` — owner-only details/poster URL if ready.
- `GET /movie-night/stream/movie/tt1234567.json` — one secure file URL only if indexed and currently valid, else zero streams.
- `GET/HEAD /movie-night/media/tt1234567` — existing owner-only file with byte-range 206 and headers suitable for Android TV/Media3; **never** a filesystem URL, public endpoint or untested source.

No broad Origin/Host exception, CORS allow-all, identity bypass, or cross-site POST/API exposure. The separate generic `AFZ Movies & TV` manifest/streaming gateway remains unchanged.

## Acceptance and rollback

Verified on 2026-10-27 Toronto:
- 27 isolated gateway tests on H3/WSL (existing identity suite + new addon tests), plus syntax/pinned source/hash checks; all passed.
- HP Envy gateway-only three-file rollout and `afz-movie-night-access.service` restart; source hashes matched preflight. Automatic rollback script passed live acceptance.
- Live owner HTTPS through Tailscale: manifest 200; five catalog rows; five media stream rows; one-byte GET Range 206; media HEAD 200; existing AFZ Movies & TV manifest on 8448 unchanged with 19 catalogs.
- The live gateway's own owner/unsafe Origin/fetch checks returned 200/403 as appropriate; the five rows exactly matched the existing download index.
- Pixel 10 Pro XL AFZ Nuvio preview versionCode **167** already installed; owner-only addon deep link was accepted and new manifest URL is present in local addon preferences (two references). No APK reinstall, account reset or phone download. Physical video playback and OnePlus/Onn client-visible Home row remain unverified.
- No change to stored picks, ratings, genres, jobs, download files, media index, ZBook backend, existing general addon, Tailscale Serve, or private owner config.

Deployment branch/PR and owner task are linked from the handoff. HP Envy rollback is **owner-only**:
`/home/coolyo/afz-stremio-secondhost-20260918/state/movie-night-access/rollback/nuvio-ready-20261028T031405Z/`
contains the original `standalone_server.py` and `movie_gateway.py`. If regression occurs, after verifying current deployed source hashes and owner/session constraints, atomically restore both files, remove only the new `nuvio_ready_catalog.py`, and restart **only** `afz-movie-night-access.service`. Do not revert Movie Night itself, restore old selections, change Serve, or delete movies.

## Future enhancement

A dedicated first-class Nuvio native connected-mode row can later show pending/download progress, explicit profile-bound selection parity and notifications without installing a separate addon. That requires explicit Nuvio client work and account/profile/revision guards, not a general unauthenticated movie list. Avoid collision with the existing native-TV and 503 stream-preflight claims.
