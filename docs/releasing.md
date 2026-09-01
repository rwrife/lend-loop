# Releasing Lend Loop

The first candidate is `v0.1.0-rc.1`, with Flutter build name `0.1.0` and build
number `1`. Public metadata is pinned in `release/rc.env`; application metadata
is in `pubspec.yaml`. Use Flutter 3.47.1 / Dart 3.13.1 from `.flutter-version`.

## Clean verification

From a clean checkout:

```bash
export PATH="$HOME/flutter-3.47.1/bin:$PATH"
flutter --version
flutter pub get --enforce-lockfile
./scripts/check_release_metadata.sh
make verify-rc
```

`make verify-rc` runs locked dependency resolution, formatting, static analysis,
the complete headless suite, lifecycle integration, and supported packaging.
On Linux it builds Android and explicitly reports that iOS requires macOS/Xcode.
On macOS it also produces an unsigned iOS archive and simulator app. Generated
logs, packages, and verified SHA-256 manifests are under the dedicated
`.artifacts/release-candidate/` root and are ignored by Git. An overridden
`RELEASE_OUTPUT_DIR` is accepted only when its resolved path ends with that
exact dedicated suffix. Each platform directory contains snapshots of the
metadata, clean, dependency, toolchain/command, and build logs covered by its
manifest; the root evidence log records successful manifest verification and is
retained alongside the platform directory in CI.

To package only one platform after the same clean metadata checks:

```bash
./scripts/build_release_artifacts.sh android
# macOS with Xcode only:
./scripts/build_release_artifacts.sh ios
```

Android produces an installable debug APK plus release APK/AAB outputs. Without
local key properties the release outputs are unsigned and labeled `unsigned`.
iOS produces an unsigned `Runner.xcarchive` ZIP and an unsigned simulator app
ZIP. These outputs prove compilation only—not signing, installation, launch,
store readiness, simulator interaction, or physical-device behavior.

## Android signing boundary

Release builds are never signed with Flutter's debug key. If
`android/key.properties` is absent, the Gradle release signing configuration is
absent. Both the properties file and keystore formats are ignored by Git.

For a local signed build, keep the keystore outside the repository and create an
untracked `android/key.properties`:

```properties
storeFile=/absolute/private/path/to/upload-keystore.jks
storePassword=<from a password manager>
keyPassword=<from a password manager>
keyAlias=<configured upload alias>
certificateSha256=<64-hex SHA-256 fingerprint of the intended signing certificate>
```

Then run the Android packaging script. It verifies each APK/AAB using an
available compatible `apksigner` or `jarsigner`, compares the certificate with
`certificateSha256`, and refuses an unexpected signature. Requested signing
fails when verification cannot pass; non-requested/unverified output is labeled
`unsigned`. Obtain the expected fingerprint directly from the controlled upload
certificate and compare it out of band. Never paste passwords or keystore bytes
into an issue, PR,
build log, screenshot, release note, or source file.

Optional CI signing must use protected environment secrets such as
`ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`,
`ANDROID_KEY_PASSWORD`, and `ANDROID_KEY_ALIAS`. A trusted release job may
decode the keystore into `$RUNNER_TEMP`, write `android/key.properties` only for
the build, restrict permissions, verify the signature, upload the artifact, and
delete both temporary files. The repository's ordinary Quality gates do not
receive these secrets and intentionally publish only debug/unsigned artifacts.

## iOS signing boundary

The repeatable CI command and its recorded toolchain evidence are:

```bash
flutter build ipa --release --no-codesign \
  --build-name=0.1.0 --build-number=1
```

It requires macOS and Xcode and yields an unsigned Xcode archive, not an IPA for
App Store or device installation. Local distribution additionally requires an
Apple Developer team, a valid distribution certificate in the login keychain,
a matching provisioning profile, the intended bundle identifier, and reviewed
Xcode export options. Use Xcode Organizer or `flutter build ipa` with a private
export-options plist. Keep certificates, `.p12`, private keys, profiles, and
export credentials outside Git.

Optional CI signing must use a temporary keychain and protected environment
secrets (for example certificate bytes/password and provisioning profile bytes),
unlock it only for the signing job, verify the archive, and destroy the keychain
and profile afterward. No placeholder certificate/profile is committed and no
iOS signing is claimed by the unsigned workflow.

## Evidence and screenshots

Follow [`release-checklist.md`](release-checklist.md) and
[`release-test-matrix.md`](release-test-matrix.md). Attach exact command logs and
the retained release evidence log (commit, host/toolchain, shell-escaped
commands, signing results, and checksum verification) while separating static
analysis, automated tests, unsigned builds,
simulator checks, manual accessibility, and physical devices.

Do not create marketing screenshots from widget tests, mocks, or a design file.
Use the exact runnable artifact with invented data and record its hash,
platform/runtime, and device profile. This candidate currently commits no
screenshots; see [`screenshots/README.md`](screenshots/README.md).

## Tag and publish only after green CI

After the packaging PR is merged, wait for the **Quality gates** push run on the
exact merge commit to succeed. Download its Android/iOS artifacts, verify their
`SHA256SUMS`, complete every evidence-backed checklist item, then create an
annotated tag and GitHub prerelease:

```bash
git switch main
git pull --ff-only origin main
source release/rc.env
git tag -a "$RELEASE_TAG" -m "Lend Loop ${RELEASE_TAG}"
git push origin "$RELEASE_TAG"
gh release create "$RELEASE_TAG" --repo rwrife/lend-loop --prerelease \
  --title "Lend Loop ${RELEASE_TAG}" --notes-file <reviewed-release-notes.md> \
  <verified-artifacts-and-logs>
```

A tag must point to the checked `main` commit. Do not reuse or move a published
tag. Do not claim App Store, Google Play, TestFlight, simulator, or device
publication unless that separate action actually occurred.
