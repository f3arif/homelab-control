# Mobile Movie Night selection downloads

The owner requested that selecting a movie in AFZ Nuvio on OnePlus download it to the server. This explicit mobile action is now separate from legacy web shortlist-only Add. It queues one movie without replacing or finalizing the existing3–10 group.

## Contract and behavior

Use the existing owner-private add-session/feedback endpoints, exact Origin and CSRF boundary. Add-session version1 advertises `selectionDownloadEnabled` only when the real download queue is active. POST feedback with action `select-download`, an exact IMDb movie ID, a16–80 character requestId and boolean retryDownload. Admission verifies released movie metadata and current Seen / Not for me rules. The asynchronous similar-status response must acknowledge selected:true and downloadRequested:true with a matching per-title download record; metadata saved alone is not success.

A SQLite transaction saves explicit selection authorization and the existing durable queue entry together. Repeated request keys cannot change intent; per-principal/movie uniqueness prevents duplicate jobs. Existing unavailable/failed/cancelled source requests retry only through an explicit new retry intent. Existing/partial files and linked failed transfers remain protected for review. Old selection history never exhausts future selections; enrichment reads only the existing API’s100 recent request identities.

The existing cached-only source/worker pipeline retains1080p5–15GB bounds, ZBook8TB identity, reserve/budget, exact concrete file binding, cancellation and full validation. Actual file/index readiness remains separate from queue acknowledgment. No second transfer engine, watched timestamp, local-device download or batch replacement was introduced.

## Verification and rollout

[Draft PR338](https://github.com/f3arif/homelab-control/pull/338), final runtime source `3ca5bfe9dfbaf7bd696fa092503bc53b4dd8ff9f`, stacked on PR336. **359/359 tests**, including13 new selection cases. Both original behavior and retained-history cap were reproduced before fixing. `tests/mobile_selection_qa.py` passes through the real production factory and real owner gateway with a disposable generated1959-byte1080p clip, actual ffprobe/hash validation, indexing/range206, duplicate protection and restart persistence. Tiny size bounds exist only inside that fixture; production settings stay unchanged.

Five unique ZBook runtime files were rolled out through pinned idle-only source swaps; the final one-module refinement is in the r2 manifest. All final runtime hashes match the source commit. Owner HTTPS capability/action/Origin/CSRF checks pass; all five existing jobs/ready movies and existing user preference/index/feedback/group/genre data are preserved. No real movie was selected or downloaded for QA. Envy gateway code, ranking PR328, delete/trailer PR323 and autotopup PR334 were not activated. Both PR338 and [native PR90](https://github.com/f3arif/AFZ-Nuvio/pull/90) remain draft/unmerged; no regular-Onn operation.

The native signed R62/build179 is delivered to OnePlus with receipt/installation limits in PR90. R59/R61 clients retain their old add-only behavior until updated.

## Source-only rollback

On ZBook, the exact deployed helper/manifests and private backups are under `/home/coolyo/AFZ/QA/MovieNight/20261103-mobile-selection/`. Use `candidate/deploy_mobile_selection.py rollback` to revert the final refinement to the original selection feature. For full feature rollback, first perform that idle-gated r2 rollback, then `candidate/deploy_mobile_selection.py rollback --manifest candidate/selection-release-initial.json` from the QA root. Each checks all pinned hashes/idle/locks before stopping only Movie Night review. Never restore the private database backups over newer user choices; source rollback preserves data and downloaded files. A schema-only empty selection table may remain for compatibility.

Safe receipts are in `qa/mobile-selection/`; private user-data backups remain on the owner’s server. Claims337/89 and the AFZ Media handoff record actual delivery and phone acceptance limits.
