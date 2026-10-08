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

Verified on 7 October 2026: 253 tests passed with no failures, errors or skips, including 18 phone recommendation/order tests, 13 download-picker tests and 4 Android download-network tests. The 0.5.1-afz-r32 / 140 APK signature matches R29. Pixel 10 Pro XL installation and phone UI presentation were verified on 8 October 2026. OnePlus UI acceptance remains pending.

Use the established Android SDK, Java 21 and original signing key. On a Windows/WSL checkout, direct build outputs and the project cache to native Linux storage to avoid slow file copying:

```bash
./gradlew :androidApp:assembleFullDebug :composeApp:testAndroidHostTest \
  --tests 'com.nuvio.app.features.downloads.*' \
  --tests 'com.nuvio.app.features.streams.*' \
  --tests 'com.nuvio.app.features.jellyfin.*' \
  --tests 'com.nuvio.app.features.player.PlayerScreenRuntimeStateTest' \
  --no-daemon --max-workers=1 --no-configuration-cache \
  --project-cache-dir /home/faiz/.local/share/afz-build-output/r32-phone-first-20261007/project-cache \
  -I /path/to/r32/native-output.init.gradle \
  -Dafz.nuvio.buildOutputRoot=/home/faiz/.local/share/afz-build-output/r32-phone-first-20261007 \
  -Pkotlin.compiler.execution.strategy=in-process \
  '-Dorg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8' \
  -Pnuvio.app.versionName=0.5.1-afz-r32
```

The verified-build.json file records the actual outcome and APK checksum. The patch passed application checking against the exact R29 Git index and reverse checking against the candidate. Focused regressions cover screenshot ordering, actual AFZ movie/episode file labels, absent recommendations, stable provider order, 1080p TV action priority, global placement/singleton deduplication, other devices and the download picker.

## Pixel verification — 8 October 2026

The user explicitly selected Pixel 10 for physical verification. On the Pixel 10 Pro XL, R29 / 137 was preserved for rollback, then the reviewed R32 / 140 APK was installed in place with app data retained. The installed base APK SHA-256 matches the reviewed artifact exactly. The signing certificate matches the previous R29 install.

- **Movie:** Insidious: Out of the Further (2026) shows the concrete 4.1 GB 1080p phone file before the AFZ source group. The same file is absent from ordinary rows. Other phone files, Auto Mobile, Data Saver and Auto 1080p precede Play Best, Auto TV and Auto 4K.
- **Device picker:** the visible choices lead with that 4.1 GB file, followed by Mobile 1080p files and Large / Original quality files. All visible choices are concrete files. No media download was started; transfer and larger-download confirmation were not physically exercised.
- **Episode:** Friends S1E1 shows the matching 1.7 GB 1080p file once above the AFZ group, under Mobile streaming option. Its 0.35–1.5 GB target is shown accurately; this file is above that target. Mobile rows precede TV Auto and 2160p choices.
- **No recommendation:** Arthur S1E1 has SD sources and shows no invented 1080p recommendation.

**Separate unresolved issue:** Friends S1E1 also receives Comet files from Conversations With Friends, Song of the Samurai, Your Friends and Neighbors and Hyakkano. Its TV Auto row points to Your.Friends.and.Neighbors.S01E01.2160p.DV.HDR.mkv (10.6 GB), an unrelated title. The featured phone file matches Friends. UI ordering passes; broad episode-source correctness is not accepted. No provider/backend configuration was changed.

Temporary portrait locking was restored to the original rotation settings. The final crash-buffer read for the current app process contains no lines; this is a bounded check, not a long-running stability test. Wireless debugging changed endpoint during the session and was rediscovered through mDNS. Tailscale TSMP/ICMP checks passed at that endpoint loss, so the user's intermittent Tailscale fault remains unresolved.

See pixel-acceptance-20261008.json for installation identity, UI cases, limitations and the separate provider issue. XML and PNG evidence is retained in the H3 candidate's pixel-verification-20261008 folder. The October 7 verified-build.json remains a historical pre-installation build record. No media playback was exercised. This PR remains draft and separate from TV PR #262.

## OnePlus acceptance pending

Inspect and back up the currently installed OnePlus preview before installation. Confirm package/signature compatibility and avoid downgrading a newer build. Install in place, keeping app data.

On the phone, refresh the screenshot movie's Sources and verify that a concrete mobile recommendation precedes Play Best and 4K/TV choices. Also check an episode and a title without a budget match. Open Download to device and confirm a fixed file is selected; Auto/HLS choices must not become downloads. Do not start a large transfer just to verify ordering.

Pixel evidence does not establish OnePlus acceptance. Keep the historical build report intact and record each physical device in its own acceptance report.

Resume key: **AFZ-NUVIO-PHONE-FIRST-R32-20261007**
