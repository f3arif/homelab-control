# FamilyPTT Phase 1 APK preparation

This request is intentionally `staged-not-active`.

It pins the successful standalone Android build from `f3arif/FamilyPTT` workflow run `33325967023`, artifact `FamilyPTT-standalone-release-apk-arm64`, APK SHA-256 `4bc8ceafe13ea42eb68cf0f682dec5dbbab9980510d642993453e8e788e9117b`, package `ca.afzeng.familyptt`, and the established two-handset pair.

This staging change does **not** bind the helper to any watcher, scheduled task, queue, or automatic execution surface. A later separately reviewed activation must both bind the typed helper and change the exact request to `active`. The helper itself refuses artifact download or ADB installation unless both exact authorized devices are present, rechecks the pair immediately before installation, and never toggles network state, uninstalls the app, or clears app data.
