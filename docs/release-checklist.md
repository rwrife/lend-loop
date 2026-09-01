# Release checklist

Use this checklist for every candidate. A checked item requires linked evidence;
do not carry checks forward from another commit or artifact.

## Version and source

- [ ] `release/rc.env`, `pubspec.yaml`, tag, release title, and changelog agree.
- [ ] Candidate commit is on `main`; working tree is clean.
- [ ] `flutter pub get --enforce-lockfile` leaves no diff.
- [ ] No signing key, certificate, provisioning profile, token, user record,
      photo, backup, local path, or generated export is tracked.
- [ ] License/notice summary and the complete resolved/bundled license set were
      reviewed against `pubspec.lock`.

## Automated verification

- [ ] Formatting: `dart format --output=none --set-exit-if-changed .`.
- [ ] Static analysis: `flutter analyze`.
- [ ] Unit/widget/adapter tests: `flutter test --coverage`.
- [ ] Lifecycle integration: `flutter test test/integration/lifecycle_matrix_test.dart`.
- [ ] Migration fixtures cover every committed schema version.
- [ ] GitHub Quality gates are green for the exact candidate commit and default
      branch; run URLs and conclusions are recorded.

## Builds, signing, and artifacts

- [ ] Android debug APK, release APK, and AAB commands completed on the pinned
      Flutter/Android toolchain; signing state is labeled.
- [ ] iOS unsigned archive and simulator app completed on pinned Flutter/Xcode,
      or the exact macOS/Xcode blocker is recorded.
- [ ] Any signed Android artifact was verified with `apksigner verify --verbose`
      or `jarsigner -verify`, and its certificate SHA-256 matches the expected
      upload signer; any signed iOS archive was verified with
      `codesign --verify --deep --strict` and the intended identity/profile.
- [ ] Artifact filenames identify candidate and debug/simulator/unsigned status.
- [ ] Build logs and `SHA256SUMS` are attached; every published file hash matches.
- [ ] No debug/simulator/unsigned package is represented as store-installable.

## Runtime and accessibility evidence

- [ ] Android emulator plugin smoke recorded, or `Not run — <reason>`.
- [ ] iOS simulator plugin smoke recorded, or `Not run — <reason>`.
- [ ] Android physical-device smoke recorded separately, or not claimed.
- [ ] iOS physical-device smoke recorded separately, or not claimed.
- [ ] TalkBack and VoiceOver checks cover primary screens, focus/reading order,
      roles/states, denied permissions, and 200% text, or are explicitly not run.
- [ ] Core record/return/export flow works with photos and notifications denied.
- [ ] Any screenshot comes from the exact runnable artifact, contains invented
      data, records platform/runtime/profile, and is labeled simulator/emulator
      when applicable. Absence of real capture evidence means no screenshot.

## Product and privacy documentation

- [ ] User guide matches record, return/undo/reopen, reminder denial,
      export/preview/restore, and delete-all behavior.
- [ ] Privacy and store metadata match the exact binary declarations.
- [ ] Release notes state no account, analytics, ads, contacts, backend, or
      hidden transfer and warn that backups are unencrypted.
- [ ] Store forms, descriptions, support links, age/content answers, and privacy
      answers were reviewed for the target store; publication is not claimed
      until accepted there.

## Tag and GitHub prerelease

- [ ] All required PR and post-merge checks are green before creating the tag.
- [ ] Annotated tag points to the verified `main` commit.
- [ ] GitHub release is marked prerelease and includes changelog, evidence links,
      artifacts/logs/hashes, signing limitations, and unavailable checks.
- [ ] Downloaded release assets hash to the published manifest.
- [ ] App Store, Play Store, TestFlight, simulator, and device claims are limited
      to evidence actually obtained.
