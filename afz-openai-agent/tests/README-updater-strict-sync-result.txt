AFZ updater strict child-sync result hardening is validated by .github/workflows/afz-updater-strict-sync-result-validate.yml.
The updater must fail closed on nonzero child exit, blank output, invalid JSON, invalid remoteSha, or exact-SHA mismatch.
No updater mutation primitive is added or removed by this hardening change.
