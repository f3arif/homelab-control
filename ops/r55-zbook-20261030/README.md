# R55 actual-ZBook rehearsal — no production deployment

Claim: homelab-control #325. AFZ Media retains the active live rollout under #324.
Source tested: PR #323 at 8f666286e603a1d16b75fb324e6a209e967b3687.

## Executed results

On 2026-10-30 at 01:36 UTC (October 29 Toronto evening), the isolated canonical-source worktree on afz-zbook passed:

- 16/16 full owner gateway, private relay and backend end-to-end tests.
- 358/358 complete server regressions, zero failures, errors or skips. The 16 E2E tests are included in the 358 total.
- 13/13 existing deletion-engine tests repeated using disposable files and fresh databases on the actual mounted ntfs3 8 TB filesystem. These are repeated cases on another filesystem, not 13 additional unique tests.

The exact live interpreter/dependency set was used: Python 3.12.15, FastAPI 0.141.1, Uvicorn 0.53.0, Starlette 1.9.0, httpx 0.28.1, Requests 2.34.2. The CI environment had Starlette 1.10.0; this rehearsal removes that environment mismatch from the untested list. FFmpeg and FFprobe were available in the service's PATH under its runtime bin directory; the ordinary Commander shell PATH did not contain them. No dependency installation was needed.

The live service PID, selected production source/database hashes, and metadata snapshot of all five movie files were unchanged before and after. All generated NTFS fixtures were cleaned up. No real movie, live database or service configuration was modified, and no production delete POST was sent.

## Evidence location and reproduction

The reusable script is `rehearse.py`. Detailed receipt and verbose logs are retained on the owner's ZBook in:

`/home/coolyo/AFZ/QA/r55-zbook-20261030T0130Z/ops/r55-zbook-20261030/`

The detailed receipt was not uploaded through the GitHub connector; this shared summary omits private database fingerprints. The script was published separately to this canonical repository. Local QA worktrees are not an alternative source of truth.

Run only from an isolated worktree under `/home/coolyo/AFZ/QA`:

```sh
/home/coolyo/afz-movie-night-runtime-312/bin/python ops/r55-zbook-20261030/rehearse.py --disposable-ntfs
```

The script refuses runtime/test source drift from the pinned commit. NTFS tests use a new randomly named directory at the volume root, never the real `Media/MovieNight/Movies` directory. Only generated fixture bytes are deleted. These results do not prove power-loss durability or real phone/TV acceptance.

## Live state checked without changing it

- Movie Night owner HTTPS returned five ready titles, HTTP 200.
- R55 deletion preflight returned HTTP 404. The live ZBook deletion module and activation flag are absent. R55 deletion is NOT enabled.
- AFZ add-on trailer metadata is now live from Grok's separate PR #50: Local 21/24, For You 6/6, Netflix Canada 9/10, Trending 24/24 and Hindi 24/24 cards have trailer references. This is metadata verification, not newly observed physical playback.
- Actual custom TV package `com.afz.nuviotv.preview`: Onn 4K Pro has TV3 Movie Night/build1074; regular Onn 4K has TV2 Search/build1073. The separately installed original `com.nuvio.tv` and mobile preview are not the same package.
- Pixel 10 Pro XL mobile preview is R53/build168. OnePlus installation/version remains unverified through ADB; no APK was installed during this audit.

Direct Commander now executes as coolyo on ZBook and on Envy/H3. The prior SSH browser-check problem does not block this session's direct authorized route. AFZ Media was notified on its active deployment claim #324. That claim and the live source were not overwritten, merged, restarted or closed by this audit.
