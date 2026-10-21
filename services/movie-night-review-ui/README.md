# AFZ Movie Night review UI — HP Envy release

This is the **standalone Movie Night review screen** served by the HP Envy
`movie-night-review-service`. It is not the Android AFZ Nuvio
"Movie Night This Week" recommendation row (separate draft PR #12).

## Deployment

Status: **live on HP Envy, 2026-10-21**. The exact live `screen.html`,
`screen.css`, and `screen.js` matched the `candidate/SHA256SUMS` after
deployment. Existing movie feedback/finalization data was untouched.
The review-service process did not restart.

Host staging:
`/home/coolyo/afz-stremio-secondhost-20260918/movie-night-ui-refresh-20261021/`

Live files:
`/home/coolyo/afz-stremio-secondhost-20260918/movie-night-review-service/src/`

Only three static page files are deployed. Backend routes, cookies,
principal checks, likes/picks/finalize APIs and saved state remain intact.
There is no automatic movie acquisition; downloads remain disabled.

## Changed UX

- Larger real posters, missing-poster placeholder, AFZ navy/cyan styling
- Concise filters and collapsible "How it works"
- Larger Pick/Picked button, clear PICK badge, sticky selection/finalize bar
- Not for me with ~9-second Undo
- **Additional review fix:** Undo now restores a previous Like instead of
  always clearing the feedback; confirmed against the existing backend's
  single-value feedback model.
- Readable runtime, genre labels, real synopsis, compact notices
- Download actions hidden while disabled

## Verification

- Candidate and original live file checksums verified.
- `node --check candidate/screen.js` and `bash -n swap.sh` passed.
- `python3 test_swap_isolated.py`: isolated apply, rollback,
  unexpected-live-drift refusal, and injected mid-swap failure restore PASS.
- `node test_undo_feedback.js`: restore prior liked and unliked feedback PASS.
- Real read-only backend shortlist: five current movies, all with summaries.
- After deployment, authenticated page and JS/CSS HTTP GET returned 200,
  and served JS/CSS matched the live candidate byte-for-byte.
- Database record counts before/after: 45 feedback, 0 finalized, 1 refill
  request. The server process ID stayed unchanged.
- Claude's earlier fixture-based layout checks covered 360, 412 and
  1280-pixel viewports. **Real-data physical phone rendering has not yet
  been independently verified**; do not claim that it has.

## Guarded apply and rollback

The deployed `swap.sh` validates candidate and rollback checksums and
refuses changed live files. It stages all replacements on the same
filesystem, renames each file atomically, and attempts to restore all
original files automatically if an intermediate step fails.
The three-file update is **not globally atomic** to concurrent requests.
There is no service restart and no state DB mutation.

On the actual HP Envy staging path:

```bash
cd /home/coolyo/afz-stremio-secondhost-20260918/movie-night-ui-refresh-20261021
./swap.sh rollback    # restore the exact original live UI
./swap.sh apply       # re-apply reviewed candidate (only when original hashes match)
```

Before any later rollout, compare the running files with the appropriate
SHA256SUMS and confirm no other agent changed the live version.
Do not force mismatched hashes, erase preferences or bypass auth.

## Limitations

Physical phone verification with authenticated real user data remains
unverified. The nine-second Undo is temporary; after timeout, a suggestion
can still be restored through the "Removed suggestions" panel, but a
restoration outside the toast defaults to clearing feedback. The service
still treats a temporary dislike of a finalized movie as needing a
re-finalization, preserving backend eligibility safeguards.

Source and tests reside in this existing `f3arif/homelab-control` repo.
The GitHub copy is canonical; the host staging folder is the deploy/rollback
location, not a separate source repository.
