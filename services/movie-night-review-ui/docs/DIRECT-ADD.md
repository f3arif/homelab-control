# Add a movie to AFZ Movie Night

The owner web app now has **Add a movie**. Search by movie title, optionally with a year; choose the exact result and press **Add to Movie Night**. The server verifies the released movie and saves it in the existing manual shortlist. Adding alone does not pick, finalize, resolve a media source or download anything.

AFZ Nuvio R59 uses the same admission action from movie details. Its Home Movie Night section shows manually added titles as a shortlist for review, separately from downloaded/ready movies. Existing Seen / Not for me feedback remains authoritative. Repeated adds deduplicate on disk; failed saves and changed feedback can be retried.

## Live deployment

- Source: `90a67f00cbb2ac5a4ec39a560a7ea6c1c1942650`, directly on the exact live PR316 baseline `2a4d33c433dd800f457fa666c68a280484c2d732`.
- Web: https://hpenvy.tailc9bb62.ts.net:8453/movie-night/
- ZBook runtime changed only `webapp.py`, `similar_movies.py`, `review_service.py`, `screen.html`, `screen.js`, `screen.css`.
- Envy owner gateway changed only `movie_gateway.py`.
- The production review route filter and gateway both allow owner-only `GET /movie-night/api/add-session`; writes use the existing CSRF / Origin guarded `POST /movie-night/api/feedback`.
- Existing owner identity, relay, private route, media policy and storage remain in force. Pending server-deletion, persisted-ranking and autotopup work was not activated.
- PR336 stays draft and unmerged; no streaming container, fleet update feed, Tailscale or Serve configuration changed.

## Verification

**346/346 Python tests passed**, with no failures, errors or skips. Two production-route regressions were first observed failing against the earlier candidate and then passed after the route-filter fix. Real gateway / Unix backend browser checks passed at **360, 412 and 1280 px**, including search, year disambiguation, real save acknowledgments, durable reload, retry, cancellation and no overflow. The browser fixture used disposable metadata and saved exactly one fixture movie while preserving its database and starting no media work.

Live owner HTTPS checks verified the new session, private no-store policy, real public-metadata title search, year disambiguation and rejection of invalid movie IDs, missing CSRF and unsafe Origin. Five finalized movies, genres, feedback and download rows were preserved; logical preference/index databases and suggestion/settings hashes stayed unchanged across rollout and live checks. No pre-existing manual movie was available for a non-mutating duplicate-add check, so **live user-list persistence was not exercised**; durable persistence is established by production-constructor and browser fixtures.

`qa/direct-add/added-360.png` is a browser fixture screenshot, not a physical phone capture or a user movie choice. The regular Onn was excluded from all testing and control.

## Source rollback

`deploy_direct_add.py` and `direct-add-release.json` pin every existing runtime source file and the six backend / one gateway candidates. They refuse source drift, back up source and private state, gate backend changes on idle media queues, and restart only the two Movie Night user services. State backups are evidence and must never be restored over newer user choices.

Both hosts retain private release material under `/home/coolyo/AFZ/QA/MovieNight/20261101-manual-add/release-direct-add-r2-{backend,gateway}`. To roll back this feature, execute the staged script with `backend rollback` on ZBook, then `gateway rollback` on Envy. Each command verifies current hashes and restores only its pinned source files; it preserves user data. Health failure automatically restores that host's previous source.
