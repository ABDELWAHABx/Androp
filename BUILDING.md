# Builds without private Actions minutes

[Public workflow](https://github.com/ABDELWAHABx/Androp/actions/workflows/public-builds.yml) runs on standard GitHub-hosted runners: `macos-26` with Xcode 26.6, `macos-15` for policy checks and `ubuntu-latest` with Java 21. These public-repository compute minutes are free. Larger runners and private-repository hosted jobs are not part of this setup.

The macOS 15 runner's Xcode 26.3 asset compiler crashed in Apple framework loading, so packaging uses macOS 26. This does not change the app's minimum macOS 14.5 requirement. The verification record distinguishes the current package checks from the preceding package's macOS 15 runtime check.

The existing five workflows in `airsync-selfbuild` are disabled. Its default branch is unchanged. The private repository holds installable releases; it does not run builds. Only pushes to the public `main` branch or an explicit workflow dispatch run the public workflow. Permissions are read-only, checkout credentials are not persisted, and there is no automatic pull-request execution or shared build cache.

## Public visibility and private installers

Source, workflow definitions, logs and test reports are public. Use synthetic test data. The Android job uploads only XML test/lint reports; signing happens locally with the existing update certificate.

The Mac job compiles, runs policy and lifecycle tests, packages, checks hashes/signatures/versions and runs the ZIP's packaged app on macOS 26. The DMG receives integrity and checksum checks. Both packages come from the same staging directory; the DMG's mounted app is not independently runtime-tested.

Before upload, Mac installers are bundled and encrypted with [age](https://age-encryption.org/), using `.github/build-recipient.txt`. Only the public recipient is in this repository. The private identity stays in the release maintainer's local workspace, outside Git, with restrictive permissions. There are no signing credentials or private-repository tokens in the public workflow. Public artifacts contain an encrypted archive, not directly installable downloads. Artifacts expire after one day and can be removed after private release publication.

A maintainer downloads the successful run's encrypted artifact, decrypts it locally, checks build metadata against the run's exact source commit, and publishes the original ZIP/DMG and checksums to a dedicated private download branch, linked from the private release page. This final handoff is separate from public CI. The current workspace credential can push repository files but receives HTTP 401 from the release-upload host, so this release uses the private download-branch fallback. Binary files increase that private repository’s size; ordinary release assets are preferable if upload access is restored. If the local identity is lost, generate a new identity, replace the committed public recipient, and rebuild; already published private installers remain available.

Example maintainer commands, run with `age` and `gh` installed:

```sh
# Keep the generated identity outside the checkout; never commit or upload it.
age-keygen -o /private/local/path/androp-build-identity.txt
age-keygen -y /private/local/path/androp-build-identity.txt > .github/build-recipient.txt
# Commit the PUBLIC recipient, then run the public workflow.
gh run download RUN_ID --repo ABDELWAHABx/Androp \
  --name androp-mac-encrypted --dir encrypted-build
age -d -i /private/local/path/androp-build-identity.txt \
  -o packages.tar.gz encrypted-build/androp-mac.age
mkdir packages
tar -xzf packages.tar.gz -C packages
# Check source and checksums before uploading to the private release.
```

Free compute does not supply Apple Developer ID signing/notarization, physical Samsung/Mac radio testing, or unrestricted artifact storage. Retention is kept short, caches are disabled and private workflows stay disabled. Check the account's Actions budget separately; disabling workflows does not reverse previously accrued usage.

Original license terms remain in `mac/LICENSE` and `android/LICENSE`. Changing where a build runs does not grant redistribution rights; installable downloads remain private/internal.
