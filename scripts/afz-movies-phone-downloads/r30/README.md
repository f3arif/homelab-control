# AFZ Movies R30 - Android TV device download entry

R30 is a guarded incremental restore patch on top of the preserved R29 source state.

## Scope

- Adds a visible, text-labelled `Download to device` action for `DownloadDevice.Television`, intended for Android TV / Onn 4K D-pad use.
- Reuses the existing R29 `deviceDownloadAction.onClick` path. That continues into the existing `downloadOnly=true` stream/device picker. No second download engine or duplicate queue path is introduced.
- Gives the television action a real focus target, minimum width, and visible focused state.
- Keeps Phone, Tablet, and Computer on the existing compact download presentation.
- Leaves the R29 phone streaming recommendation/ranking logic unchanged. Television remains outside the phone playback recommendation path.
- Bumps the candidate build number from 137 to 138.

## Source checkpoint

- Immediate base (R29): `10be7a7b0dfb650117c872705efaf9a1cc272f47`
- R30 source commit: `cb10a54da74d10647e8b157e5343057ee06bd120`
- Source branch/worktree: `afz/tv-download-r30-20261005` / `/home/faiz/afz-nuvio-tv-download-r30-20261005`
- Restore patch: `tv-download-r30.patch`
- Guard: `apply_r30.py` refuses to apply unless HEAD is exactly the R29 source commit and the tree is clean.

## Verification

- Television presentation regression: PASS.
- Existing R29 phone playback recommendation regression: PASS.
- Existing device download picker regression: PASS.
- Existing download recommendation regression: PASS.
- Full Android host suite: 1,473 completed, 2 environment-dependent failures, 6 skipped. The two failures are `AndroidDownloadLifecycleTest.classMethod` and `AndroidDownloadNetworkTest.classMethod`, both failing in Android `DefaultSdkProvider` setup on the Linux/WSL host rather than in R30 assertions. All focused R30/R29 gates passed.
- Restore apply-check from exact R29 commit: PASS.
- `:androidApp:assembleFullDebug -Pnuvio.app.versionName=0.5.1-afz-r30`: PASS.
- Package: `com.afz.nuvio.preview`
- Version: `0.5.1-afz-r30` (`138`)
- APK bytes: `160176173`
- APK SHA-256: `148083a75243fcb126a64bcc72c5e728141e5ca6c84246728a4956ae5b16537b`
- APK signer SHA-256: `2ead05d67ceb35e59a5f703af7fb17bc93c22e04370ad51ba754bb38e06b2b09` (Android Debug candidate key)

## Restore

Start from an exact, clean R29 source checkout at `10be7a7b0dfb650117c872705efaf9a1cc272f47`, then run:

```bash
python3 scripts/afz-movies-phone-downloads/r30/apply_r30.py /path/to/nuvio-source
```

If restoring from the older R26 restore point, restore R29 first using the sibling R29 workflow, verify its exact source commit, then apply R30.
