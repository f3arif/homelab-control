# Movie Night subtitles R2 — executable runtime integration

**Status: implemented and qualified, NOT activated on production.** Claim #331 follows subtitle R1 #330. Existing AFZ Media live-deployment claim #324 and ranking #327 are preserved. No current unit, original service/gateway source, APK, preference, movie, job or Tailscale route was changed.

## Concrete changes

The TV3 client `SubtitleRepositoryImpl.kt` does not always request the plain phone-style subtitle URL. It appends optional `videoHash`, `videoSize` and percent-encoded `filename` in a path segment. R1 returned404 for those paths. The bridge now accepts the exact bounded TV contract, rejecting duplicate/unknown parameters, invalid sizes/hashes, encoded traversal and malformed names. These fields are hints only: the server still uses the exact indexed movie ID and original file fingerprint, never a submitted path or URL. Both `name`/`language` and the standard `label`/`lang` are returned for client compatibility; actual UI presentation remains device-dependent.

New `src/subtitle_service_entry.py` wraps the existing backend factory in-process, attaches the subtitle routes after existing route filtering, and forwards the original arguments unchanged. The existing `main()` retains listening addresses, private socket, relay secret, RelayAuth, downloads policy and shutdown behavior. It does NOT activate deletion. The required extra argument is `--subtitle-cache <private-state-directory>`; FFmpeg/FFprobe are pinned to the existing Python runtime's bin directory. It refuses unexpected factory shape or missing indexed-download boundary.

New `gateway/subtitle_gateway_entry.py` wraps the existing owner gateway class and forwards original CLI arguments unchanged. It preserves the existing owner configuration, exact origins, port and Unix relay. It does not replace ranking/deletion/catalog modules or change configuration by itself.

New `src/subtitle_prewarm.py` is an external one-shot worker, suitable for a separately approved systemd timer. It reads existing SQLite databases in read-only/query-only mode and uses the existing `MediaVolume` guard; no missing-mount fallback. It skips active/unknown transfer state, holds an interprocess private-file lock, prepares at most two movies/four English tracks per invocation by default, and has a180-second total preparation budget. Individual tool calls inherit the remaining deadline. A completed empty-language result is remembered, missing output is regenerated, and valid file/policy-matched output is not repeatedly extracted. One failed file cannot cause an unbounded pass. Nothing schedules this worker or invokes it from player HTTP requests.

English is only the worker's preparation default; it does not change any user's subtitle preference. Other ISO639-2 language codes are an explicit worker option. Bitmap tracks remain embedded, and conversion to WebVTT does not preserve every ASS styling feature.

## Integration recipe — only for the coordinated deployment owner

1. Refresh and reconcile the current R55/ranking source and exact unit files; preserve original source/configuration and do not overwrite concurrent work.
2. Install the two R1 modules and R2 helper files in their corresponding backend/gateway directories without modifying movie files, picks, tombstones, credentials or provider settings.
3. For the ZBook service, use the existing Python with `subtitle_service_entry.py --subtitle-cache <existing-private-state>/subtitles` followed by the exact original service arguments. Do not remove or invent the original relay secret, listener, state path, origin or R55 activation policy.
4. For the Envy owner gateway, substitute only the entrypoint with `subtitle_gateway_entry.py`, keeping the original owner config/origins/socket arguments. Existing file/hash checks and rollback are mandatory before changing units/restarting.
5. Run `subtitle_prewarm.py --state <existing-private-state> --cache <same-cache>` explicitly after preflight, or connect an approved bounded external timer. Do not run extraction on a browser/player request or add a public endpoint.
6. Verify owner HTTPS plain/TV-extra subtitle requests, VTT GET/HEAD, no-owner rejection, and normal video availability. Then validate actual CC selection, Off, seeking, timing and labels on OnePlus/mobile and native Onn TV. No actual user film should be deleted as a test.

The helper entrypoints are **not deployment scripts**. No unit files, timers or startup state were created or enabled by this work. Source-only rollback can restore the former entrypoints while leaving original movies and all deletion tombstones untouched.

## Executed qualification

On ZBook using its existing runtime: **15/15 new runtime/compatibility tests pass** and **398/398 full server regressions pass**, with zero failures/errors/skips. The15 are included in398. New full-chain tests use the real owner HTTP gateway -> private Unix relay -> relay-secret authentication -> FastAPI -> private generated subtitle cache. They exercise both the TV-extra path and VTT GET/HEAD, preserve default-off deletion, reject foreign owner/Origin and direct unauthenticated backend requests, and retain playable streams when captions are unavailable.

Additional checks cover preserved startup arguments/factories, completed-cache policy, missing output regeneration, cross-process worker exclusion, transfer-idle refusal, no-track negative caching and hard preparation deadlines. Fake movie/subtitle bytes and fresh temporary databases only; no user movie playback, server activation, API deletion or client installation.

Previous R1 real-file extraction remains evidence of format/timestamp compatibility, not proof that the new feed is visible in the installed apps. This R2 did not repeat real-film extraction or claim device subtitle rendering.

Canonical source: f3arif/homelab-control branch `chatgpt/movie-night-subtitle-runtime-20261030`, stacked on `chatgpt/movie-night-subtitles-20261030`. Evidence: `qa/subtitles-runtime/validation.json`. Production deployment coordination remains `homelab-control#324`; do not silently take over that active scope.
