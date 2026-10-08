# AFZ episode release identity — 8 October 2026

Friends S1E1 received files from Conversations With Friends, Song of the Samurai, Your Friends and Neighbors and Hyakkano. Its TV Auto row could select an unrelated 10.6 GB episode. The backend accepted quality/provider data without validating most series titles, including in cached and error-fallback results.

The fix validates the complete series-title prefix and season/episode against IMDb-keyed metadata before ranking or creating Auto choices. Explicit filename years must match the series. Fresh results, cache hits, busy-provider fallbacks and exception fallbacks share the filter. Direct resolution checks the selected token against the filtered episode rows before consulting a cached URL.

Punctuation, accents, scene tags, numeric titles such as 1923, SxxExx / 1x01 / Season–Episode formats, paired episodes and explicit episode ranges are covered. The existing Hey Arnold S1E38→provider S1E20 mapping and episode-title constraint are preserved; source URLs retain the requested episode identity and translate only inside the resolver. Movie resolution and local-file selection are unchanged.

## Verified outcome

- Python syntax validation and **37 focused tests passed**, zero failures or errors. A comparative test reproduces the original wrong-show Auto choice. Tests exercise cache/error paths, rejected stale resolver URLs, metadata outage handling, movie resolver isolation and the existing remap.
- The final source is live on H3, manifest **0.6.243**, SHA-256 **d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f**. Runtime checks passed for the complete Friends S1E1 response: all 11 playable entries match Friends S1E1, including Auto. Arthur's existing local file remains and the unrelated Arthur (2015) file is excluded. An excluded pre-deployment file token returns **404** before media resolution.
- On the physical Pixel 10 Pro XL running the existing R32 preview, a refreshed list shows a matching **1.6 GB 1080p** Friends file before the source group. Its 1.7 GB alternative follows; Auto points to the matching Friends episode. All three final captures came from the same refresh; all 14 captured source descriptions (including scroll overlaps) match Friends S1E1, and the featured row appears once. Earlier full-list captures showed a matching 1.9 GB file first; provider responses changed between refreshes. No media was played or queued for download. Original rotation settings remain 1/0; the current app crash-buffer check has no lines.

The first deployment attempt stopped at a changed-provider baseline gate before any source or process change. After inspecting the refreshed response, verification captured a currently excluded file token rather than requiring one old filename to remain. The first deployed revision passed 35 tests; a follow-up numeric-title correction passed 37 tests and is the final live hash above. Both completed deployment records and rollback copies are retained privately on H3.

## Scope and limits

The filter deliberately hides files whose series identity cannot be established. Filenames with no series title, unsupported localized aliases or unverifiable numbering can be legitimate but remain excluded until their identity can be verified. Known cached IMDb metadata can sustain identity during an outage; absent identity yields no external choices. Local playback files remain available.

These checks validate source identity and presentation, not media-content inspection, full playback/download behavior, all possible release conventions, OnePlus acceptance or sustained Tailscale stability. Provider settings, Real-Debrid's disabled state, bridge code and launcher configuration were preserved. The Pixel APK was not rebuilt or replaced for this backend fix.

## Reproduction and preservation

`apply_episode_identity.py` stages the patch only against exact baseline SHA-256 **3a51419da35600ffa9668e3e60923a63459afb76e5e6325bf4fd1c0eed7a347f**. It preserves baseline bytes, builds the candidate, emits a unified patch and verifies that only three existing functions changed, with three helpers added.

```bash
python3 apply_episode_identity.py /path/to/inspected/stremio_catalog.py /path/to/stage
python3 /path/to/stage/test_episode_identity.py
```

The staged directory must also contain the test helper. The full baseline/candidate and token-bearing runtime data are retained privately rather than committed. The portable patch, staging helper, tests and sanitized evidence are in this package.

`deploy_episode_identity.ps1` is the audited H3 rollout helper for the final follow-up revision. It pins the previous deployed hash **889d370d3b960740e84a2d7878ccbef934248eddb5b1a2b8570128acf188d68c**, candidate hash, tests, launcher and bridge, validates the active core process, uses the existing deployment mutex, backs up the source, restarts only that core and rolls back on verification failure. Review its exact host/base gates before any future deployment; completed jobs must be inspected rather than replayed.

Private evidence: `C:\AFZ\Nuvio-Setup-20260923\episode-identity-20261008`. Pixel XML/PNG evidence: the existing R32 candidate's `pixel-verification-20261008` folder. The original R32 app review remains PR #263; Android TV PR #262 is separate.

Resume key: **AFZ-EPISODE-IDENTITY-20261008**.
