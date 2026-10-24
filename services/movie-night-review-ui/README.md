## Editable genre settings — 2026-10-24

Use **Edit genres** on Movie Night to add or remove included/excluded genres, then **Save genres**. An empty include list means any genre; an empty exclusion list permits all genres. A title matches any included genre, and any excluded genre vetoes mixed-genre matches. Moving a genre between the lists removes it from the other list. Cancel discards the draft.

Initial choices preserve the current seven preferred genres and Animation, Drama and Comedy exclusions. These are migration defaults, not enforced permanent exclusions. Settings live in the instance's private `genre-settings.json`; they persist across restarts and devices. Revision checks reject stale saves. Corrupt settings fail closed rather than silently resetting preferences. The current single-owner access boundary, origin and CSRF requirements apply. Settings saves refresh metadata only; finalization remains the explicit download trigger.

The API returns `genreSettings: {included, excluded, revision, options}` in the shortlist. Save through the existing `POST /movie-night/api/feedback` route with `{action:"set-genre-settings", settings:{included,excluded,revision}}`. Unknown genres, duplicates, overlap and excluding every genre are rejected; an old revision gets 409. The stable genre taxonomy is an input allowlist, not a hardcoded preference list. Discovery catalogs, metadata screening, publication/refill, ranking and new finalize/source eligibility all use saved preferences. Historical fixed title vetoes for genres have been removed; supplied genre evidence remains authoritative. Seen/disliked and year/intensity rules remain.

An excluded saved title remains a history note and its completed media stays accessible. Eligible retained titles can return when filters are relaxed. Saving filters never silently rewrites finalized IDs, likes, media jobs or files. The 3–10 pick limit and 5–15 GB 1080p downloads to the 8 TB drive are unchanged.

# Movie Night — 8 TB storage and 5–15 GB downloads

Owner policy, 2026-10-24: finalized movies download directly to the ZBook's **8 TB AFZ_MEDIA** drive. Each new movie must be a known-size cached **1080p file between 5,000,000,000 and 15,000,000,000 bytes inclusive**. Smaller or oversized files never become fallbacks. The existing 50 GiB free-space reserve and 100 GB transfer budget remain; archived attempts count toward that budget. File size is a selection constraint, not a guarantee of visual quality.

The review/download backend runs on `afz-zbook`. Media root: `/srv/afzmedia/Media/MovieNight/Movies`. Exact mount `/srv/afzmedia`, NTFS3 UUID `A29E635A9E63264F`, writable status and 8 TB capacity are checked before transfer, during progress, before publication and when serving media. Missing/wrong/read-only storage fails closed without creating an internal-disk fallback.

The existing owner URL remains `https://hpenvy.tailc9bb62.ts.net:8453/movie-night/`. Envy keeps the owner gateway and a private Unix-socket relay; ZBook accepts the backend port only from Envy's tailnet address plus a private per-service secret. No billing credentials are forwarded. No Tailscale SSH policy changes are needed. New media bytes are written only on the 8 TB disk; state databases and application dependencies use the ZBook's internal disk.

`deploy_8tb.py` implements guarded `export-envy`, `install-zbook`, and `connect-envy` steps. Transfer the private archive through the already-authorized H3 SSH connections, verify its SHA-256, and retain it owner-only. `migrate_storage.py` verifies copied media, preserves completed files, archives cancelled jobs and their original authorizations, retains preferences, and makes unfinished requests retryable as new jobs under the new policy. It never overwrites media or silently resumes a partial with a different source. The previously completed 3.96 GB file is retained as historical content, not treated as a new qualifying download.

Emergency recovery: run `deploy_8tb.py pause-zbook` in the canonical ZBook checkout. It cancels active work and restarts the backend in review-only mode while preserving the latest preferences, jobs and all media. Do not restore an old Envy database or run a historical Envy apply/rollback script after cutover. Reconnecting to the old backend requires an explicit current-state migration; retained Envy files are recovery copies, not active storage.

Tests cover inclusive size boundaries, bounded inventory, exact-volume refusal, relay peer/secret enforcement, migration preservation/rollback, and a generated-video browser transfer through the private relay onto the actual 8 TB volume. `tests/auto_qa.py` uses only fixture providers; `AFZ_QA_8TB=1 AFZ_BROWSER_SCRIPT=storage_browser.cjs` enables the real-volume fixture. Tests temporarily lower the size minimum for tiny generated media only; production has no CLI minimum override. The production 5–15 GB boundary is tested independently with metadata fixtures.

## Daily use

Owner filter, 2026-10-24: exclude Animation and Drama, including mixed genres, alongside the existing Comedy exclusion. The same policy applies to reviewed suggestions, discovery, refill banks, publication and new finalize/download eligibility. Previously saved excluded picks are shown as compact history notes; remaining eligible picks stay selected for review. Completed server files and feedback are preserved.

Owner preference, 2026-10-24: match the preferred genres without requiring every recommendation to resemble a liked movie. Explicit likes remain first; other eligible movies receive a simple genre-match preference, with reviewed order preserved for ties. Shared obsession, relationship-tension, suspense or twist tags no longer boost ranking, and extra matching genre labels earn no additional boost. Already-screened preferred-genre films can qualify without those theme tags. The old similarity badge is removed. Existing genre/year/intensity screening, watched/disliked exclusions and saved choices remain in force. This change applies to the shortlist, reviewed refills and discovery candidate ranking through their shared ranker.

Turn on Tailscale and open the dedicated Movie Night URL. Pick 3–10 movies, then press **Finalize & download**. Pick and Like alone start nothing. Server downloads show source checking, queued/downloading progress, unavailable/failed results, cancellation and completion. Missing source checks can be retried; completed files offer a separate copy to the current device. A completed historical file is preserved even if it predates the new minimum.

Finalized movie cards show current server status directly. **Ready on server** appears only for downloaded and indexed files, with the size and **Save a copy to this device** link. Downloading cards show byte progress; the finalized summary and picks tray count ready movies. Polling also follows the downloaded-to-indexed transition. **View download details** focuses that movie's row. If a status request fails, the cards report that status is unavailable and hide file links until a successful refresh; queued, incomplete and failed files never get a ready link. These read-only updates do not start downloads or claim playback has been tested.

The queue first checks existing completed TorBox inventory, then Comet metadata and TorBox cache metadata. Cached-only acquisition never opens an addon's playback URL or starts an uncached torrent. Fresh exact title/year, provider/file IDs, completion/safety flags, codec and size bind each authorized job. Duplicate requests cannot dispatch twice. Transfers write exclusive partials and validate length, SHA-256, 1080p dimensions and codec before non-overwriting publication. Downloaded, indexed/available and observed playback are separate states.

The owner gateway and CSRF/origin protections are unchanged. The 8 TB guard and relay are server-only. Keep provider configuration and relay secrets outside Git, mode 600 in private directories. Nuvio remains a separate planned client; see [the integration plan](docs/AFZ-NUVIO-INTEGRATION.md). No APK or Jellyfin/Radarr integration is implied by this backend move.

## Verification and recovery

The Python 3.12 runtime must install all direct dependencies from `requirements-runtime.txt`. In particular, `requests` is needed for uncached posters and Cinemeta discovery, even if cached posters and the rest of the page work. The 2026-10-24 poster repair restored this omitted dependency without changing application files or restarting services. Keep the qualified existing package versions when repairing an environment; record the before/after package inventories and constrain existing versions during installation.

From the project checkout:

```sh
uv pip install --python /path/to/venv/bin/python -r requirements-runtime.txt
PYTHONPATH=src:tests:.test-deps python -m unittest discover -s tests -v
AFZ_QA_8TB=1 AFZ_BROWSER_SCRIPT=storage_browser.cjs python tests/auto_qa.py
```

`tests/test_posters.py` exercises the default HTTP client, cache misses/hits, timeout recovery and existing format/size/redirect/path limits. `tests/posters_live.cjs` visits the actual owner page with writes blocked, scrolls every lazy poster into view at 360/412/1280px, and checks successful image decoding rather than treating a placeholder as success. Also qualify a real uncached fetch in a disposable poster cache on the target runtime; fixture injection alone does not test optional imports.

The fixture test must use the documented target runtime, browser, fonts and library paths from the deployment handoff. Never substitute real provider credentials or real user finalization as QA.

Canonical source is `f3arif/homelab-control`, subtree `services/movie-night-review-ui`. PR #291 is stacked on #289; earlier #287/#285/#283/#281/#278 remain preserved. Historical deployment scripts describe their original releases only and must not be applied over the current distributed backend. The current handoff records exact commit, private migration receipts, live checks and the safe pause command.
