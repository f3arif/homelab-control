# R55 — Owner-confirmed deletion of Movie Night server copies

Status: **QUALIFIED IN DISPOSABLE FIXTURES; NOT LIVE.** This feature introduces a destructive capability. Merging or copying source must not activate it. The owner requested the ability to delete individual server copies in Nuvio, but has not authorized deletion of any particular real movie. All deletion tests use fictional IDs, tiny temporary files and fresh databases.

## Scope and user-visible behavior

Under R54's native **Movie Night → Ready on server** row, the owner can request **Delete from server** for one indexed file. A read-only preflight returns the canonical title, size, 120-second one-use confirmation and CSRF. **Keep movie** cancels with no changes. Only the separate **Delete server copy** confirmation may unlink the exact verified file.

Successful deletion removes the file and its ready-catalog entry, while retaining a private tombstone. The download list, individual-job status and previous finalized selection report **Removed from server**, not stale Ready. Other server files, phone-local copies, watch history, ratings, likes and saved selections remain untouched. No automatic watched-state cleanup or scheduled deletion is included. Re-finalizing an old selection, recovering an interrupted queue or replaying an old job does not re-download an intentionally removed title. A deliberate restore/re-download flow is separate work.

## Explicit activation, default off

`build_app(..., server_delete=False)` is the default, even with downloads enabled. The ordinary backend CLI requires the additional `--server-delete` flag, and rejects it without `--downloads`. A deployment using a custom factory/relay entrypoint must likewise explicitly opt in through the factory after approval; updating source alone is insufficient.

Without this opt-in, destructive endpoints are absent and the deletion service/tombstone schema is not newly created. **Existing tombstones are still respected** for status, source lookup, queue recovery and workers even if deletion is later switched off. Never roll back tombstone data or remove these read guards, because that could revive an intentionally deleted title.

## Protected server contract

The existing Tailscale owner boundary, exact external Host/Origin and backend relay secret remain mandatory. No direct public deletion port, credential forwarding, TLS exception or CORS wildcard is introduced.

- `GET /movie-night/api/delete-server/{imdb}` returns `{imdb,title,sizeBytes,confirmationToken,csrfToken,expiresInSeconds:120,requiresExplicitConfirmation:true}` through the owner gateway, private no-store. Preview checks the index, mounted storage, actual file identity/size and active transfers. GET never deletes.
- `POST /movie-night/api/delete-server` requires exact `{imdb,confirmationToken,confirmedTitle}`, string types and bounded lengths, correct Origin/CSRF and the owner's unexpired one-use title confirmation. Wrong title, replay, replaced inode, changed size, missing volume, foreign identity or active work fails closed.
- The filename is restricted to `tt<IMDb>.<year>.mkv/mp4` inside the verified Movies directory. Directory FD, no-follow and device/inode/size/mtime checks bind the operation to the previewed file; no arbitrary client path is accepted.
- Ready catalogs and streams use the original MediaIndex. Tombstone checks now happen **before** provider/source lookup, worker resolution and transfer—not merely when attempting late index registration.
- Individual job status, old approval replays and downloads-list status consistently suppress downloaded/indexed/playback flags for removed files.

## Reproduced bugs and qualification

The initial full-chain suite against immutable source `c6fe9a6e71ce8d510136da1289fd938c4e6bacd6` reproduced three gaps: individual job status stayed indexed; proposing a removed title still scheduled lookup; a stale approved worker resolved/fetched fixture bytes before late tombstone rejection. All three are fixed in qualified source commit `fcd248d069cd643701522eeb29c1f2176a606c1d`.

Verification uses a real loopback HTTP owner gateway → private Unix relay → relay authentication → FastAPI backend → temporary SQLite and files. It does not connect to a production server. First nine full-chain tests passed on H3. The extended GitHub-hosted run passed **16/16 end-to-end checks** and **358/358 complete server regressions**, with zero failures, errors or skips. The 16 tests are included in the 358 total, not additional unique cases. The existing generated-video/FFprobe test also ran; FFmpeg was installed on the disposable runner instead of skipping it.

Evidence:
- Run: https://github.com/f3arif/homelab-control/actions/runs/40816998527
- `qa/r55-e2e/e2e.json` and `qa/r55-e2e/full.json`: precise counts, dependency versions and SHA-256 of tested source.
- `tests/test_server_delete_e2e.py`: cancellation, owner/CSRF/relay boundaries, actual fixture deletion, catalog/stream removal, unchanged other files/history/picks, expiration/replay, concurrent confirmation, malformed request, restart, stale worker/queue, re-finalization and default-off activation.
- `ops/r55-e2e-20261029/run_qualification.py`: non-loopback network guard and reproducible receipts.
- `ops/r55-e2e-20261029/apply_qualification_fixes.py`: historical immutable-base patch recipe. Do not run this on already-patched source; it intentionally refuses drift.

The CI workflow is now **read-only** and checks the committed source directly. The initial one-time guarded source/receipt commit did not merge a branch or deploy anything. No APK or phone/TV installation, production restart, database migration or real media deletion occurred.

## Remaining rollout gates

Server PR #323 and native PR #46 remain drafts. Before production activation: review current source hashes and deployment entrypoint, confirm the actual ZBook volume/owner boundary, prepare source-only rollback that retains tombstones, obtain the protected activation approval, and verify the native phone and TV interactions. A successful loopback fixture is not real-device acceptance, Tailscale acceptance or a durability guarantee under power loss.

Rollback must be pinned to the actual current ZBook `movie-night-review-service/src` and Envy `movie-night-access-service`, not an obsolete pre-migration host. Disable the destructive capability without restoring old jobs/index data or deleting tombstones. Existing server films must never be used as disposable tests.
