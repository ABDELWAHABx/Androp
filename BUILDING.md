# Builds without private Actions minutes

[Public workflow](https://github.com/ABDELWAHABx/Androp/actions/workflows/public-builds.yml) runs on standard GitHub-hosted runners: `macos-26` with Xcode 26.6, `macos-15` for policy checks and `ubuntu-latest` with Java 21. These public-repository compute minutes are free. Larger runners and private-repository hosted jobs are not part of this setup.

The macOS 15 runner's Xcode 26.3 asset compiler crashed in Apple framework loading, so packaging uses macOS 26. This does not change the app's minimum macOS 14.5 requirement. The verification record distinguishes the current package checks from the preceding package's macOS 15 runtime check.

The existing five workflows in `airsync-selfbuild` are disabled. Its default branch is unchanged. The private repository holds installable releases; it does not run builds. Only pushes to the public `main` branch or an explicit workflow dispatch run the public workflow. Permissions are read-only, checkout credentials are not persisted, and there is no automatic pull-request execution or shared build cache.

## Public visibility and private installers

Source, workflow definitions, logs and test reports are public. Use synthetic test data. The Android job uploads only XML test/lint reports; signing happens locally with the existing update certificate.

The Mac job compiles, runs policy and lifecycle tests, packages, checks hashes/signatures/versions and runs the ZIP's packaged app on macOS 26. The DMG receives integrity and checksum checks. Both packages come from the same staging directory; the DMG's mounted app is not independently runtime-tested.

The Mac job uploads the ZIP, DMG, BUILD.json and checksums as the `androp-mac` artifact on the run page. It is not encrypted. Artifacts expire after one day. There are no signing credentials or private-repository tokens in the public workflow.

To install: download `androp-mac` from the successful run, unzip it, open `androp-v0.1.0-preview.6-arm64.zip` (or the DMG) and drag `androp.app` to Applications.

Free compute does not supply Apple Developer ID signing/notarization, physical Samsung/Mac radio testing, or unrestricted artifact storage. Retention is kept short, caches are disabled and private workflows stay disabled. Check the account's Actions budget separately; disabling workflows does not reverse previously accrued usage.

Original license terms remain in `mac/LICENSE` and `android/LICENSE`. Changing where a build runs does not grant redistribution rights; installable downloads remain private/internal.
