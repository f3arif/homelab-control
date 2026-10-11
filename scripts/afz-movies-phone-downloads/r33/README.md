# R33 add-on setup candidate

R33 accepts HTTP, HTTPS and Stremio schemes regardless of case while preserving provider path and token case. Completed manifest fetches commit an add-on atomically, so simultaneous installs of the same normalized URL produce one row. Existing enabled state and user name are retained when a duplicate arrives.

Base source: `1922ff0108e8b99c1f0be74c0592d251c5fb63a9` (R32).
Candidate source: `333523bb7cd247552e84417e7a4ee358858885c7`.
Patch SHA-256: `dc8a1d232849a4dd02104e91ad4f0eb43c3a5a63fb92d1eab0c0192be803cc31`.
App candidate: `com.afz.nuvio.preview / 0.5.1-afz-r33 / 141`.

## Validation status

Source diff checks passed, and applying the saved patch to the exact R32 base reproduces candidate tree `5038fb2fde91190483359ddb61f32e78ce800174`. The R32 checkout remains unchanged. Thirteen new tests cover case normalization, path/token preservation, 64 simultaneous duplicate arrivals repeated 20 times, simultaneous distinct add-ons, existing disabled state, and reinstall after removal.

The verified full-debug build completed at 2026-10-11 04:21:33 UTC / 00:21:33 Toronto. All 270 selected Android host regression tests passed with zero failures, errors or skips: add-on tests 13, phone recommendation tests 18, download picker tests 13, plus the existing downloads/streams/Jellyfin/player runtime selection. Package/version identity and signing-certificate equality with the preserved R32 APK passed.

APK: `AFZ-Movies-R33-addon-setup.apk`, 160174117 bytes.
APK SHA-256: `1fc1a7a8cd14c74cb650312b16590e96e5f9afcb5b9b26c37122b0577a3ed2cd`.
See `verified-build.json` for the captured result.

The first build was interrupted during resource preparation. The second encountered a corrupted project-cache lock left by that interruption. Both attempts and the old R33-only cache are preserved. The successful third build ran independently under the one-shot Windows task `AFZ Nuvio R33 Build 20261011` with a fresh cache. There is no recurring trigger.

Pixel 8 setup acceptance passed at 2026-10-11 04:51:50 UTC / 00:51:50 Toronto. R33 was installed in place and its installed APK hash matched the candidate. Uppercase HTTPS recognized the existing AFZ add-on and successfully fetched/installed a fresh Cinemeta test add-on. Eight subsequent Stremio deep-link requests retained exactly one Cinemeta row. The temporary test add-on was removed; the original AFZ add-on settings are unchanged, with one active add-on and 19 catalogs. Guest profile Pixel8 and completed Friends S1E1 remain, with actual file size 2,002,704,356 bytes. Only the download reconciliation timestamp changed after launch. XML/PNG captures were inspected privately; see `pixel8-r33-acceptance-20261011.json` for sanitized evidence. The repeated physical requests targeted an already-installed add-on; the completed-fetch concurrency race is covered by host tests, not a controlled physical race.

The fresh wireless endpoint connected using existing pairing on a separate Pixel 8-scoped ADB server at port 5038 after the shared server failed. The shared server and other devices were untouched. The installer now accepts an optional reviewed server-port argument (5037 by default, 5038 for the isolated session). Never rerun the installer on an accepted R33 device; its R32/version and prior-installation guards deliberately reject that. No media transfer or network-isolation test was repeated. App was force-stopped after verification.

H3 durable evidence: `C:\AFZ\Nuvio-Setup-20260923\R33-addon-setup-candidate`.
Native checkout: `/home/faiz/afz-nuvio-r33-addon-setup-20261011`.
Native build output: `/home/faiz/.local/share/afz-build-output/r33-addon-setup-20261011`.

Apply the patch only to the exact clean base commit using `git apply --check` first. Build uses the existing private local configuration and signing key; neither is included here. Profile switches during a pending fetch are outside this fix's scope.
