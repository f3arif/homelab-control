# AFZ Movies R28 — download picker corrections

Phone download rankings treat consistent rounded size labels such as 65.1 GB and 65.11 GB as the same file and conservatively retain the larger value. Large files stay under Large / Original quality. Reopening a sheet retries failed or empty lookups; download mode preserves add-on setup and fetch failure feedback and shows loading when provider rows are not yet populated. Playback keeps its source order.

## Verified build

- Android: 0.5.1-afz-r28 / versionCode 136, package com.afz.nuvio.preview.
- Source commit: 2df1fd2d25c318be4d8214bc5f27685dc18af39b.
- APK SHA256: ba975f712405dbb1503ab6f890575cf171944c0051ea2adcb5a9d7074b8e94e4.
- All 235 download, stream, routing, Jellyfin and player checks passed; zero failures/errors/skips. Thirteen new regressions cover rounded sizes, budget boundaries and failed-result handling.
- Pixel 10 Pro XL updated in place, preserving preference hashes and existing download file inventory.
- Final APK delivered to OnePlus 13R via Taildrop; R28 installation is pending because its debugging port closed. Last verified OnePlus version remains R27.1.

## Restore

This full patch includes R27.1 and R28 on top of the reviewed R26 base 0c3340c3364205de5be368a84f74293372f504b2. The guarded applier requires that exact clean head. Apply to a new clean worktree, not over a newer candidate.

```bash
python3 apply_r28.py /path/to/clean-afz-r26
```

Use the existing AFZ Android SDK, Java 21 and signing key. Build with -Pnuvio.app.versionName=0.5.1-afz-r28 and run the established download/stream/Jellyfin/player and Android routing gate before installing. The full patch passed git apply --cached --check against the exact R26 base. APKs and rollback evidence remain on H3; this directory contains text source and build metadata only.
