# AFZ phone-first source ordering — R32

R32 carries the October 7 phone-ordering work into a guarded, numbered patch against the exact tested R29 source. This package is independent of Android TV R30 download-entry PR #262.

The reported movie list put Play Best and 4K/TV choices ahead of a 3.2 GB phone file. R29 also anchored its phone recommendation after Play Best. R32 renders the original recommended phone file once, before every add-on/source group, and removes its duplicate from regular rows. A singleton recommendation stays visible.

On Phone playback lists, remaining rows are stably ordered as explicit AFZ Phone/TV Mobile 1080p files, Auto Mobile, Data Saver, Auto 1080p, other suitable 1080p rows, Play Best, controls/other sources, Auto TV, then Auto 4K. Ordering also applies when no recommendation is available. Explicit TV/Play Best labels retain their priority when descriptions mention 1080p.

TV, Tablet and Computer retain their quick-action presentation. The download-only picker retains its file ranking, fixed-file eligibility, size caps and larger-download confirmation. Source resolution, providers and server behavior are unchanged.

## Restore

Use a clean checkout at preserved R29 source commit **10be7a7b0dfb650117c872705efaf9a1cc272f47**:

```bash
python3 apply_r32.py /path/to/preserved-r29-source
```

The helper verifies the exact base, clean checkout and patch checksum before applying. It refuses changed/newer checkouts. The patch includes versionCode 140; build with versionName **0.5.1-afz-r32**. Review/rebase before incorporating this into a later source revision. Do not apply the earlier illustrative r30/phone-first-r30.patch.

## Build and validation

Use the established Android SDK, Java 21 and original signing key:

```bash
./gradlew :androidApp:assembleFullDebug :composeApp:testAndroidHostTest \
  --tests 'com.nuvio.app.features.downloads.*' \
  --tests 'com.nuvio.app.features.streams.*' \
  --tests 'com.nuvio.app.features.jellyfin.*' \
  --tests 'com.nuvio.app.features.player.PlayerScreenRuntimeStateTest' \
  --no-daemon --max-workers=1 \
  -Pkotlin.compiler.execution.strategy=in-process \
  '-Dorg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8' \
  -Pnuvio.app.versionName=0.5.1-afz-r32
```

The verified-build.json file records the actual outcome and APK checksum. The patch passed application checking against the exact R29 Git index and reverse checking against the candidate. Focused regressions cover screenshot ordering, actual AFZ movie/episode file labels, absent recommendations, stable provider order, 1080p TV action priority, global placement/singleton deduplication, other devices and the download picker.

## OnePlus acceptance pending

Inspect and back up the currently installed OnePlus preview before installation. Confirm package/signature compatibility and avoid downgrading a newer build. Install in place, keeping app data.

On the phone, refresh the screenshot movie's Sources and verify that a concrete mobile recommendation precedes Play Best and 4K/TV choices. Also check an episode and a title without a budget match. Open Download to device and confirm a fixed file is selected; Auto/HLS choices must not become downloads. Do not start a large transfer just to verify ordering.

Do not substitute Pixel/TV evidence for OnePlus acceptance. The build report must retain deviceInstalled=false until installation and verification occur.

Resume key: **AFZ-NUVIO-PHONE-FIRST-R32-20261007**
