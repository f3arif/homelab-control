# R33 add-on setup candidate

R33 accepts HTTP, HTTPS and Stremio schemes regardless of case while preserving provider path and token case. Completed manifest fetches commit an add-on atomically, so simultaneous installs of the same normalized URL produce one row. Existing enabled state and user name are retained when a duplicate arrives.

Base source: `1922ff0108e8b99c1f0be74c0592d251c5fb63a9` (R32).
Candidate source: `333523bb7cd247552e84417e7a4ee358858885c7`.
Patch SHA-256: `dc8a1d232849a4dd02104e91ad4f0eb43c3a5a63fb92d1eab0c0192be803cc31`.
App candidate: `com.afz.nuvio.preview / 0.5.1-afz-r33 / 141`.

## Validation status

Source diff checks passed; the R32 checkout remains unchanged. Thirteen new tests cover case normalization, path/token preservation, 64 simultaneous duplicate arrivals repeated 20 times, simultaneous distinct add-ons, existing disabled state, and reinstall after removal.

The first build was interrupted during resource preparation when its process disappeared. Its status and log were preserved. A second build runs independently under the one-shot Windows task `AFZ Nuvio R33 Build 20261011`. Build/test/signing results and Pixel 8 installation are pending.

H3 durable evidence: `C:\AFZ\Nuvio-Setup-20260923\R33-addon-setup-candidate`.
Native checkout: `/home/faiz/afz-nuvio-r33-addon-setup-20261011`.
Native build output: `/home/faiz/.local/share/afz-build-output/r33-addon-setup-20261011`.

Apply the patch only to the exact clean base commit using `git apply --check` first. Build uses the existing private local configuration and signing key; neither is included here. Profile switches during a pending fetch are outside this fix's scope.
