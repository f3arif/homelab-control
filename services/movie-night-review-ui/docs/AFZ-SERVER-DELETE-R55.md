# R55 — Owner-confirmed deletion of Movie Night server copies

Status: **STAGED FOR REVIEW, NOT LIVE.** This feature introduces a destructive capability; it must not be deployed merely by merging a branch. The owner has requested the ability to delete individual server copies in Nuvio after viewing or rejecting a movie, but has **not authorized the deletion of any particular real movie**. All functional deletion tests use disposable fake files.

## Scope and user-visible behavior

- Under R54's native **Movie Night → Ready on server** row, a **Delete from server** action is available only on an owner-authenticated, up-to-date, individually indexed movie.
- Tap once: a private, read-only preflight fetch returns the canonical title, exact file size, 120-second one-use nonce and session CSRF. No file is touched.
- A separate confirmation modal names the movie and approximate size and warns that removal is permanent on the 8 TB server. **Keep movie** cancels safely. **Delete server copy** performs the sole destructive POST.
- On success, the exact file is removed from `/srv/afzmedia/Media/MovieNight/Movies` and its validated MediaIndex entry is removed. A private tombstone suppresses accidental re-import/re-download and labels an old finalized selection **Removed from server**.
- **Do not delete** a separate device-local Nuvio download, watch history, prior Like/Seen/Not-for-me feedback, user picks, unrelated files or an active transfer. No automatic cleanup, scheduled deletion or behavior tied to playback end.
- If the owner wants to re-download a previously deleted title, a future separate deliberate tombstone reset/explicit re-finalize flow is needed. Never silently undo an owner deletion.

## Protected server contract

The existing Tailscale Serve owner identity remains mandatory; the private HP Envy gateway still checks exact Host and external Origin. No direct ZBook public port, credential forwarding, cookie privilege or unrestricted CORS.

- `GET /movie-night/api/delete-server/{imdb}`: exact IMDb ID only, authenticated owner; bounded 32 KB JSON reply `{imdb,title,sizeBytes,confirmationToken,csrfToken,expiresInSeconds:120,requiresExplicitConfirmation:true}`, private no-store. Reads the MediaIndex row and checks the mounted disk, real path, type, size and current transfer state. Repeated previews replace prior one-use challenges. A GET is **never** destructive.
- `POST /movie-night/api/delete-server`: exact `Origin` and `X-Movie-Night-CSRF` required, owner-only private gateway to backend; exactly `{imdb,confirmationToken,confirmedTitle}`. CSRF and per-title nonce must match, not expire or be replayed. The title must match fresh canonical metadata. If the file, identity, transfer status or mounted volume changed, refuse with no mutation.
- Before unlink, validate file name `tt<IMDb>.<year>.mkv/mp4`, dir FD under trusted 8 TB Movies, file stat including device/inode/size/mtime, matched SQLite row and no active approved/downloading job or queued/checking source operation. Use `unlink` only for this exact verified basename, never user-provided paths.
- Additive private `removed_media` tombstones prevent old worker registration and make the original live `/api/downloads` status report `removed` (not `indexed`). The owner-only Nuvio ready catalog reads the original MediaIndex and immediately omits removed files.
- On unsafe path, zero-index state, stale nonce, insufficient permissions, missing 8 TB disk, wrong owner or session, failed CSRF, active transfer or network failure: fail closed. Never re-enable a movie from a cached request. No deleting real files from QA.

## Qualified work and limitations

Development branches:
- Server: `f3arif/homelab-control`, `gpt/movie-night-confirmed-server-delete-20261028` based on existing draft #316.
- Native: `f3arif/AFZ-Nuvio`, `gpt/r55-movie-night-delete-20261028` stacked on R54 draft #44.

Initial Python verification: 13 disposable file deletion tests, 20 strict owner-gateway tests, 8 Nuvio-ready catalog tests, total 41/41 passing in WSL. Tests verify success, cancellation, stale/cross-owner challenges, changed inode, symlink, wrong title, active transfers and tombstone preventing re-import. Native build/physical OnePlus acceptance and real server deployment are separate gates.

**Rollback**: source rollback must be hash-pinned to the existing deployed ZBook `movie-night-review-service/src` and Envy `movie-night-access-service` directories; never copy from an old pre-migration server. Staging this code does not authorize rollout, system service restart, Tailscale Serve change, 8 TB volume change or media cleanup.
