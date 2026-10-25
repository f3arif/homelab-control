## Movie Night reference-title discovery

The web owner entry offers a title/year autocomplete popup while typing and explicit related-movie search. Type at least two characters; tap an option or use arrows/Enter. Client title lookups are debounced and serialized, and stale responses cannot replace newer typing. Dismissal, IME composition and keyboard selection are handled in the web frontend; the API contract is unchanged. Nuvio may reuse the existing authenticated feedback endpoint contract:

- `search-titles` with `query` → `jobId`; poll `similar-status` with that ID until `titles` is returned. Up to 40 unique validated options are ranked from a bounded provider pool. Exact titles and shorter prefixes lead; an optional year disambiguates names. Preserve the returned order and do not truncate to the previous 12 options. This affects reference lookup only; older/watched reference movies are allowed.
- `title-preview` with a valid title-search `jobId` and offered `imdb` → a new job; poll `similar-status` until `title` includes descriptive `movieInfo` (cast, director, runtime, rating, synopsis) and genres. Title responses advertise `previewsEnabled`. The web popup lazily requests visible rows serially, retains the parent title job, and shows same-origin posters. Native clients should keep this optional, preserve selection when details fail, and ignore stale responses. Previewing never adds, picks or downloads a movie.
- `find-similar` with the title-search `jobId` and a returned `imdb` → a new job; poll for `reference`, validated `movies`, `similarReasons`, `searchScope: "all-genres-and-years"`, and `partial`. Rows include `canAdd` and `selectionBlock` (`seen`, `dislike`, `known-seen`, or null). Show all rows, disable Add when `canAdd` is false, and label why.
- `add-similar` with the result job ID and returned movie ID → refreshed normal review payload. This does not pick, finalize or download.

Explicit reference search ignores ordinary genre/year/intensity preferences and is not bound to `genreSettings.revision`. Cast/director filmographies improve regional coverage; verified shared country adds a ranking preference, not a hard country filter or a Bollywood label. Show reasons honestly, including genre-only matches. Clear/reference changes must ignore stale responses. Adding a result grants that stored row an explicit preference exception (`manualSuggestion` in the review payload); it stays selectable across ordinary genre changes. Normal recommendations remain filtered. Seen/dislike, released metadata identity/freshness, 3–10-pick, explicit finalize, 1080p 5–15 GB and 8 TB storage contracts remain enforced. The API is private owner access, not a new public endpoint. No APK changes are included.

## Editable Movie Night genres — 2026-10-24

Movie Night now owns persistent include/exclude genre settings. A future connected Nuvio editor must render the server's `genreSettings.options` and save the `included`, `excluded`, and `revision` fields through the existing authenticated/CSRF-protected feedback endpoint with `action: "set-genre-settings"`. Handle 409 by loading current settings and letting the owner review their draft. Do not embed Animation/Drama/Comedy or the previous preferred genres as immutable client rules. No included genres means any; no exclusions means none. Exclusions override mixed-genre matches. Keep `finalized.excludedIds` as history notes and retain existing server-file access.

These settings belong to the current single-owner Movie Night instance and persist across devices. Multi-profile integration must explicitly introduce profile-scoped state and discovery; do not expose this shared owner editor to unrelated profiles. Settings saves do not finalize or enqueue downloads. This change updates the web server and integration contract only; no native APK was changed.

# Current Movie Night storage contract — 2026-10-24

The shared Movie Night backend now targets the ZBook's 8 TB AFZ_MEDIA disk, `/srv/afzmedia/Media/MovieNight/Movies`, while retaining the owner entry at `https://hpenvy.tailc9bb62.ts.net:8453/movie-night/`. New finalized server downloads require cached 1080p files of **5–15 GB inclusive**; unknown, smaller and larger sizes are excluded. `GET /movie-night/api/shortlist` exposes `downloadPolicy` with `minBytes`, `maxBytes`, `quality`, `storage`, and `host`. Nuvio should display that contract and distinguish “8 TB drive” from a separate “Save to this device” copy.

This is the server contract and integration plan. No Android APK is changed here. The existing owner gateway, CSRF and exact-file binding remain. A missing/wrong/read-only 8 TB volume stops downloads; there is no Envy/internal-disk fallback. Completed historical files remain available even if below the newly requested minimum. Migration archives old cancelled attempts and allows a new bounded source choice rather than overwriting their partial files.

The older plan below remains useful for shared-list/profile/API work, but references to HP Envy as the movie storage destination are superseded by the ZBook/8 TB destination above. Keep the Envy URL as the private front door; do not expose the backend relay port to Nuvio or embed its secret in an APK.

# Movie Night and AFZ Nuvio integration plan

Updated: 2026-10-24 UTC. Owner: AFZ Media. Access claim #282; automatic-finalization claim #288 / PR #289.
Scope: separate web access is implemented in this change. The Android integration below is a plan; no APK is changed or installed by this task.

## Starting point, verified from source

The independent entry is `https://hpenvy.tailc9bb62.ts.net:8453/movie-night/`. Tailscale Serve authenticates the caller; a private allowlist admits only the existing owner's exact account. The gateway binds to loopback and exposes only Movie Night routes. No billing password, cookie or billing endpoint is used. The old billing entry on 8447 remains available for compatibility. Both reach the same private review socket and stable internal principal, so existing feedback, finalized selections and jobs are preserved.

Standalone source: `f3arif/homelab-control`, `services/movie-night-review-ui/`, 8 TB storage PR #291, stacked on automatic-finalization #289, source-feedback #287 and the access/download predecessors. `src/webapp.py` owns review/confirmation APIs; `src/feedback.py` persists feedback and finalization; `src/screen.js` currently keeps unfinalized Pick buttons in a browser-local in-memory Set. Draft picks are therefore NOT synchronized today. The owner now authorizes **Finalize & download** to automatically acquire and download 3–10 selected eligible films. The web request saves finalization and a durable per-movie queue atomically; Pick/Like alone have no acquisition side effect. Old saved picks do not enqueue merely on activation. Files go directly to the 8 TB drive on ZBook; phone copies are separate.

AFZ Nuvio PR #21 is an open draft at `579d79c81338eed7431127629744f9bba47a1ea5`. R48 build161 was built but its handoff reports no installation. Native source was independently read on H3, WSL **Ubuntu-24.04**, `/home/faiz/afz-nuvio-r48-movie-night-daily-20261023`, clean commit `6e79f7c4e1c256cd4fb9e87049254c3b9ef9bd5a`. Do not confuse that native commit with the GitHub receipts commit.

Current native paths under `composeApp/src/commonMain/kotlin/com/nuvio/app/features/home/`:

| File / class | Current behavior | Integration change |
|---|---|---|
| `HomeScreen.kt` | Builds account/profile/watch-source/language scope; runs a local daily picker and watched exclusions | Explicit connected-owner mode, then render server order and server state |
| `MovieNightCandidateProvider.kt` | Uses configured addon catalogs/TMDB and watched seeds | Bypass in connected mode; retain only as separately labelled local recommendations |
| `MovieNightRepository.kt` / `MovieNightSession` | Profile-safe local cache, daily ranking, persistent local dismissals | Add server repository with cancellation/generation guards and a separate cache namespace |
| `MovieNightPolicy.kt` | R48 permits Drama tags; excludes Comedy/dramedy; selects/ranks locally | Do not rerank or silently re-filter the connected server shortlist |
| `composeApp/src/commonMain/composeResources/values/strings.xml` | “Movie Night Picks”, daily wording | Connected, stale, unavailable and server/device download wording |

`MovieNightSession.refresh()` currently returns empty when watched seeds are empty. A connected server list must not inherit that gate. Its `dismiss()` only changes the local cache, so merely swapping the candidate loader would still leave two different lists.

Server policy update, 2026-10-24: connected Movie Night excludes Animation, Drama and Comedy, including mixed genres and aliases. Honor `excludedGenres` and `finalized.excludedIds`; excluded historical picks must not render as selectable movie cards. Preserve existing server downloads and show eligible remaining picks for explicit re-finalization. The native R48 local policy above is historical and has not been changed by this server release.

## Delivery sequence

### 1. Entry link, then an explicit connected mode

Add an “Open Movie Night” action using the dedicated HTTPS URL in an Android Custom Tab/default browser. No embedded credentials or unrestricted WebView. Check Tailscale connectivity and give an actionable offline message. This is the smallest useful Android release.

Next add an opt-in “Use my server Movie Night” setting, bound to one explicitly selected Nuvio account/profile. Preserve the existing local picker, watch history, downloads and settings. A profile switch or logout cancels in-flight calls and clears the connected row from memory before any new profile can render it. Do not map every Nuvio profile to the shared owner list automatically. Other household members need a separately authorized identity/principal design later.

Before editing, refresh both repos and all claim-board pages. Preserve R48/PR #21 and confirm the actual installed version/signing identity. The GitHub R48 PR currently carries operations receipts; reconcile the exact native source into an auditable branch of the existing AFZ-Nuvio repository before publishing an integration change. Do not create another canonical repository or edit a different agent's worktree.

### 2. Native read-only row from the same server

Create `MovieNightServerClient` and `MovieNightServerRepository` in the existing home feature. Use the app's established HTTP stack, bounded timeouts/response sizes and normal TLS verification. Tailscale adds identity at the server proxy; the app must never synthesize a `Tailscale-User-Login` header, ship a billing password or store provider keys.

Fetch `/movie-night/api/shortlist`; render the same ten visible cards in server order, the saved finalization and `/movie-night/api/downloads` status. Resolve relative poster paths against the configured origin. Persist only a bounded owner/profile-scoped snapshot, mark it stale when offline and disable mutations. Do not silently fall back to a different list. An access denial hides cached private data until the owner reconnects. Refresh on foreground/reconnect and after each successful mutation, with bounded polling only while visible.

Keep server Movie Night “Seen” separate from Nuvio's playback/watch history until an explicit reconciliation feature is designed. Never bulk-import historical Skip/dismissal as “Not for me”: those actions had different meaning. Likewise, do not apply native daily shuffling to the continuously replenished server list.

### 3. Shared choices and feedback

Add an authenticated, non-cacheable `/movie-night/api/session` endpoint returning a versioned client contract, CSRF token and enabled capabilities. This endpoint does **not exist yet**; today the token is in the HTML meta tag. Native code must not scrape that HTML. Extend both the backend and exact gateway allowlists together.

Retain exact external Origin checking and `X-Movie-Night-CSRF` on writes. The standalone gateway normalizes a successfully checked external Origin to the backend's legacy origin; never let a client choose the backend origin or principal. For native requests set the documented public Origin explicitly. Authentication remains the owner Tailscale identity on every request, with no CORS wildcard or general bearer bypass.

For true cross-device Pick synchronization, add a server draft resource before advertising it: `GET/PUT /movie-night/api/selection` with `{ids, revision}` and compare-and-swap conflict handling. This is a proposed contract, not a current endpoint. Limit drafts to ten eligible IDs; Finalize still requires 3–10. Add a revision-aware finalize operation so one device cannot silently overwrite a newer selection. Store draft and finalization atomically with their revision, and update the web UI to consume the same resource. Do not automatically merge competing selections or replay an uncertain finalize.

Current APIs to preserve:

| Action | Existing request | Required handling |
|---|---|---|
| Feedback | `POST /movie-night/api/feedback`, `{imdb,value}` | Use existing backend values; explicit Like / Not for me / Seen / Undo semantics |
| Refill | Same endpoint, `{action:"request-refill",requestId}` | Preserve existing deduplication; no download side effect |
| Finalize & download | `POST /movie-night/api/finalize`, `{ids,startDownloads:true,requestId}` | Explicit action labelled with its download effect; 3–10 eligible IDs; durable idempotency key. Extend with draft revision later |
| Retry unavailable source | Same endpoint, plus `{retryDownloads:[imdb]}` | Explicit retry only; retain the same requestId when checking/replaying an uncertain write |
| Prepare source | `POST /movie-night/api/propose`, `{imdb}` | Poll returned `lookupId` at `/api/lookup/{id}` |
| Legacy approve exact file | `POST /movie-night/api/approve`, `{confirmationId,binding,reply:"yes"}` | Compatibility path; connected automatic mode uses Finalize & download instead of manufacturing a yes reply |
| Queue / jobs | `GET /api/downloads` returns `requests` and `jobs` | Merge requests by jobId; show source lookup, unavailable/failed, queued transfer, progress and completed states |
| Status / cancel | `GET /api/status/{confirmationId}`; `POST /api/cancel`, `{requestId}` for automatic queue or `{confirmationId}` for jobs | Preserve completed files and durable state; cancellation never deletes media |

All abbreviated `/api/` paths above are under `/movie-night`. Confirm exact current response DTOs in `webapp.py` and `movie_night.py` when implementing; add a schema version and contract tests before shipping native mutations. No arbitrary query parameters on exact asset/API routes.

### 4. Playback and downloads with clear destinations

Keep separate actions: **Finalize & download to server** uses the owner-authorized automatic server workflow; **Download to this device** uses Nuvio's existing concrete-file download manager or copies a completed authenticated server file. Never label a server transfer as a phone download. Phone preferences remain suitable cached 1080p around 3–5 GB; do not alter TV/large-original ranking as part of list integration.

Automatic lookup checks existing completed TorBox inventory, then the existing Comet metadata and TorBox cache. It may add the chosen cached hash with cached-only enforcement; it never launches uncached acquisition or opens addon playback URLs. A fresh completed/safe account-file check binds exact identity, size, destination and codec before transfer. Show unavailable sources honestly and offer explicit retry. App restart resumes status observation; an uncertain request is reconciled by its idempotency key, never given a new key silently. No retroactive downloads on merely connecting a profile, opening the app or seeing previously finalized picks.

For completed media, use the existing authenticated catalog/media paths and verify the selected player and native download engine keep access to the same Tailscale route. Test GET Range/206, seek, cancellation, source disappearance and device-local completion; add HEAD support only if the chosen client requires it. Keep “downloaded”, “available/indexed” and “playback tested” distinct. ZBook/8 TB storage is implemented by this server release. Jellyfin indexing remains separate work.

## Acceptance and rollout gates

Use disposable movies/provider/video for all write/download tests. Verify web/native list parity by IMDb and revision; Like, Seen, Not for me and Undo on each surface; two-device draft conflicts; 10-pick limit; invalid/stale finalization; offline and access revocation; switching profiles mid-request; expired CSRF/confirmation; duplicate approval; cancel/restart; unavailable sources and low storage. Never verify by changing real saved choices without the user's instruction.

Run the existing native Movie Night policy/session/catalog/UI tests plus new contract/profile-isolation tests and the full Android host suite. R48's recorded baseline is 1729 passing tests, not a claim about the future integration build. Verify phone layout, TalkBack and TV remote focus where supported. Preserve signing key/package and increment versionCode. Stage a signed build and exact source/receipt; obtain installation authorization, then verify on Pixel 10 Pro XL and OnePlus 13R. No physical-device acceptance is implied by desktop browser emulation.

Roll out entry link → read-only connected row → shared drafts/feedback → automatic finalized transfers/playback, with independent flags and a retained local-picker mode. Rollback disables connected mode without erasing existing local data or server feedback/jobs. Android rollback after a version increase requires a forward-version rebuild, not an assumed in-place downgrade. Gateway rollback is `movie-night-access-20261023/deploy_access.py rollback`; it removes only the new entry and leaves the backend/download state intact.

Next implementation task for AFZ Media: claim the Nuvio entry-link/connected-read phase, reconcile the exact native source and stage a reviewable APK. This plan does not authorize APK installation or new provider accounts. The owner explicitly authorized the server Finalize & download workflow; native integration must preserve that visible action and must never trigger it on read, login or background sync.

Identity reference: https://tailscale.com/docs/features/tailscale-serve#identity-headers (verified 2026-10-23). Serve strips supplied identity headers; loopback-only binding and an exact owner allowlist are essential to this deployment.

