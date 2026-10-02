# AFZ Movies R27.1 phone downloads

The Download to device picker previously promoted a single recommended file, then retained playback and provider ordering for every other file. A 37.4 GB REMUX and a 73.2 GB 4K file could appear above phone downloads.

R27.1 ranks concrete files across the selected add-ons: a suitable cached 1080p movie near 3–5 GB first, other mobile 1080p choices, Data Saver, other 1080p, other sources, 4K, and Large / Original quality. Episodes use a 0.35–1.5 GB target. Dynamic Auto links remain available for playback; the download sheet offers fixed sources that can resume without changing files. Playback groups retain their existing order, including AFZ Play Best. Download headings and empty-state text use explicit theme colors for dark mode.

## Source and validation

- Base: `0c3340c3364205de5be368a84f74293372f504b2` (AFZ R26).
- Verified implementation: `f4cbb226c8614b8283b773fdc29cba0d8fe3d55d`.
- Android package: `com.afz.nuvio.preview`.
- Build: `0.5.1-afz-r27.1`, version code 135.
- 222 regression tests passed; 0 failures, errors or skipped tests. Includes 13 new picker cases and 4 Android routing cases.
- Full debug APK assembled and matched the existing AFZ signing certificate.
- Pixel 10 Pro XL updated in place; preference hashes and download file inventory remained identical during installation.
- The verified APK was delivered to OnePlus 13R through Tailscale. Its previous wireless ADB endpoint was closed; installation there is pending.

## Apply and build

Use a clean R26 checkout recovered from the existing AFZ source or R26 bundle; the AFZ custom head is separate from upstream Nuvio. Run `python3 apply_r27.py /absolute/path/to/source`. The script checks the exact base, rejects local changes and verifies patch applicability before editing.

Use the established AFZ Java 21 and Android SDK configuration, retain the existing signing key and full native libraries, then run:

```sh
./gradlew :androidApp:assembleFullDebug :composeApp:testAndroidHostTest \\
  --tests 'com.nuvio.app.features.downloads.*' \\
  --tests 'com.nuvio.app.features.streams.*' \\
  --tests 'com.nuvio.app.features.jellyfin.*' \\
  --tests 'com.nuvio.app.features.player.PlayerScreenRuntimeStateTest' \\
  --no-daemon --max-workers=2 \\
  '-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8' \\
  -Pnuvio.app.versionName=0.5.1-afz-r27.1
```

Require at least 222 passing tests, including all 13 picker and 4 routing cases. Verify APK package, version and certificate before an in-place update; preserve app preferences and downloads. Large-source ordering does not relax the existing download size limits.
