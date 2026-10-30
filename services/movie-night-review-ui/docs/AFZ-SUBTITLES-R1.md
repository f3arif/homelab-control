# AFZ Movie Night subtitles R1

**Implemented and tested, NOT deployed.** Claim #329. This is an additive server-side subtitle fallback for the existing mobile and native TV players; no APK was modified, installed or sent. Existing embedded subtitle playback is retained. Active R55 deployment #324 and ranking #327 were not modified or taken over.

## Grounded findings

Read-only FFprobe inspection on the actual ZBook found English text subtitles in **all five indexed Movie Night MKVs**. Thirteen Lives also contains English forced/SDH, Hindi, Arabic and other languages. The directory contains no separate SRT/VTT/ASS files. Both Nuvio clients already contain subtitle menus, embedded-track handling, sidecar parsing and timing controls. The private Movie Night addon previously advertised no subtitle resource and no inline stream subtitles.

From the current sources:
- Mobile: `StreamFetchSupport.kt` maps stream subtitles into `externalSubtitles`; `PlayerScreenContent.kt` merges these with addon tracks; `PlayerSidecarSubtitles.kt` handles WebVTT and existing delay controls. `AddonSubtitleLoader.kt` also queries the standard subtitle resource.
- TV3: `StreamResponseDto.kt`, `StreamScreenViewModel.kt` and `StreamSidecarSubtitles.kt` carry inline tracks into the player; `SubtitleRepositoryImpl.kt` queries subtitle resources.
- The default mobile preferred subtitle language is None in source; this work does NOT change the user's saved language or force captions on.
- The official OpenSubtitles v3 manifest and two subtitle requests returned HTTP403 from H3 during this check. That is evidence for that path/time only, not a universal outage. No broken addon, new provider account, credential or third-party service was installed.

## New modules

`src/server_subtitles.py` opens an exact MediaIndex-resolved movie read-only, validates its path/type/identity and prepares text tracks into a separate private WebVTT cache. It supports embedded SubRip, WebVTT, ASS/SSA and mov_text/text conversion through the existing FFmpeg. Bitmap/DVD/PGS tracks are left embedded; it does not claim OCR or text conversion for them. External `.srt` upload/import and internet subtitle searching are outside this R1.

`gateway/nuvio_subtitle_bridge.py` provides an explicit optional handler for the existing owner gateway, preserving Host/Origin/Tailscale-user checks, no-store responses and existing video/catalog logic:
- `GET /movie-night/subtitles/movie/tt....json` returns standard `{subtitles:[{id,lang,label,url}]}`.
- `GET/HEAD /movie-night/subtitle-files/tt.../<file-version>-s<track>.vtt` serves UTF-8 WebVTT through the same private HTTPS origin.
- Existing `stream/movie/tt....json` results gain `subtitles` only on the exact matching local Movie Night media URL. Existing provider streams and their subtitle lists are not overwritten.
- The existing manifest gains a movie `subtitles` resource. Inline stream fields can work without relying solely on a cached manifest refresh.

Only same-file tracks are offered. No guessed movie titles, arbitrary paths/URLs, external downloads, global CORS exception or public subtitle library. Deleted, unindexed, hidden, changed, replaced or tombstoned movies cannot serve old cached subtitles. Movie files are never rewritten or transcoded. Cache failures leave the original video available instead of blocking playback.

Language, forced and hearing-impaired metadata is retained. The standard response includes labels such as English [Forced] or English [SDH], but **the exact label presentation in each installed client still needs checking**; current TV/mobile models do not consistently consume provider labels. Do not claim a distinct labelled UI without device verification.

## Timing and bounded execution

A generated-media regression caught FFmpeg shifting the first subtitle cue to zero. Extraction now explicitly uses `-copyts`; the test verifies a cue at 0.200–1.200 seconds stays at those times and preserves UTF-8 Arabic text.

Preparation is NEVER triggered by HTTP reads. An explicitly integrated background completion/prewarm task must call `cache.prepare(imdb, languages=..., max_tracks=...)` after indexing or during an idle startup pass. Per instance, only one preparation runs at a time. Default track budget is eight; maximum64; probe deadline15s; extraction deadline90s per track; output under1.9MB/track, below existing relay limit; private cache budget128MiB. Preparation may be retried explicitly if a cold file takes too long, but must not block playback or retry endlessly on player requests.

Cached lists/assets carry a source fingerprint from device/inode/size/mtime/ctime, plus per-asset SHA256. Changed movie and tampered cache are rejected. Private cache permission/type checks, no-follow file descriptors, strict IDs and bounded subprocess output prevent arbitrary access. No shell invocation, client-chosen executable or network source is used.

## Tests actually run

On **afz-zbook**, using the existing service Python3.12.15, FastAPI0.141.1, Uvicorn0.53.0, Starlette1.9.0 and runtime FFmpeg/FFprobe:
- **25/25 new subtitle tests pass**: cache, language/forced/SDH, Unicode, actual generated two-track video, exact timing, timeout/output caps, corrupt/symlink/hardlink/replaced/deleted files, owner/Host/Origin/duplicate-identity guards, query/traversal rejection, actual loopback manifest/stream/subtitle GET and HEAD, video survival when captions are unavailable.
- **383/383 complete server tests pass**, including those25, zero failures/errors/skips. The first full invocation omitted the existing `PYTHONPATH` setup; it was corrected and the complete suite passed. No production runtime changed.
- A separate real-format check extracted **one existing English track into private QA cache**: **31,144 bytes / 598 WebVTT cues**, first cue21.855–24.358s. Movie metadata snapshot, index database fingerprint and live service PID stayed unchanged. It took59.29s; this validates why extraction belongs off the playback-request path.
- No dialogue text, subtitle file, owner identity, secret, cookie or private DB fingerprints were committed. Aggregate results and source hashes are safe to share in the repo.

Run:
```sh
cd services/movie-night-review-ui
export PATH=/path/to/existing/runtime/bin:$PATH
PYTHONPATH=src:gateway:tests python -m unittest discover -s tests -p test_server_subtitles.py -v
PYTHONPATH=src:gateway:tests python -m unittest discover -s tests -p 'test_*.py'
```

## Activation and remaining work

These modules are opt-in and do not self-activate. Existing deployment/ranking owners must reconcile current source first. Add the backend routes **after** the factory's route filtering, using its EXISTING trusted authorization callback and keeping the outer RelayAuth. Point the cache at a separate private runtime-state folder, never the movie directory. Opt the instantiated owner gateway into `enable_subtitles(server)` before serving; it refuses unexpected replacement handlers. Preserve current ranking/deletion and the deployed trailer changes.

Prewarm selected languages off the request path for existing/new indexed files, then check real authenticated HTTPS, cached-manifest behavior, and actual playback/CC selection/Off/delay/seek in **both OnePlus mobile and native Onn TV**. Do not start a real movie or mutate history just to label a fixture test as device acceptance. Physical display, default-language behavior, internet subtitles and general non-Movie-Night streams are not verified by this server-only change.

No service restart, Tailscale routing change, production endpoint activation, client install, movie deletion, movie download, settings change or PR merge was performed. Rollback removes only the optional hooks and generated cache—not media, user selections or deletion tombstones.

References: official Stremio subtitle response contract (`id`, `url`, `lang`, optional `label`) and Android Media3 WebVTT/sidecar documentation were checked. Runtime/client source, not assumptions about upstream versions, determined the integration.
