# AFZ Movies R29 — visible phone streaming recommendation

The streaming source sheet now shows **Recommended for this phone** directly after **AFZ Play Best**. It favors playable 1080p movie sources around 3–5 GB, with cache preference and a smaller episode target. The featured source is removed from its previous position to avoid a duplicate row. Its original StreamItem, proxy information and existing playback/resume callbacks are retained.

Play Best remains first. Tablet/TV/computer playback keeps its existing presentation. Streaming playlists and sensible mobile auto links can be featured; device downloads still require concrete supported files. A 1080p source outside the ideal target is labeled **Mobile streaming option**, bounded to 8 GB for a movie. REMUX, UHD, unknown-size, camera/season-pack and external-control sources cannot become the phone recommendation. Raw torrents require configured debrid access before they can be featured.

- Source commit: `10be7a7b0dfb650117c872705efaf9a1cc272f47`.
- Immediate base: R28 `2df1fd2d25c318be4d8214bc5f27685dc18af39b`.
- Branch/worktree: `afz/phone-streaming-recommendation-r29-20261002`; `/home/faiz/afz-nuvio-phone-streaming-r29-20261002`.
- App: `com.afz.nuvio.preview`; `0.5.1-afz-r29`; versionCode **137**.
- Validation: **246 tests passed**, zero failures/errors/skips, including 11 new streaming cases and the existing picker, Android routing and playback regressions.
- APK signer matched the existing AFZ signing key.
- The complete R26-to-R29 patch passed an apply check against the exact R26 base.
- APK: `AFZ-Movies-R29-phone-streaming.apk`; 160494392 bytes.
- SHA256: `e273e16e8a694c5074192e460856aa97ec073aa3f201040b54116b96e60615be`.

## Restore

Use a clean AFZ R26 checkout at `0c3340c3364205de5be368a84f74293372f504b2`. The restore script refuses a different head or local changes.

```sh
python3 apply_r29.py /path/to/AFZ-R26
```

Build with the existing AFZ SDK and signing key, using `-Pnuvio.app.versionName=0.5.1-afz-r29`, and rerun the regression gate before installation. This directory preserves the full source patch and verified build metadata; the APK stays on H3 and is delivered through the existing phone workflow.
