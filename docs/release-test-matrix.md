# Cross-platform release test matrix

Lend Loop's automated matrix uses only temporary directories, in-memory seeded
SQLite databases, and injected plugin fakes. It never reads contacts, user
photos, external files, notification history, accounts, or network services.

## Exact evidence categories

Release evidence must be recorded under these categories, without treating one
category as proof of another:

1. **Automated headless** — commit SHA, Flutter/Dart versions, host OS, command,
   pass/fail, test log, coverage, and migration-fixture results.
2. **Unsigned build** — Android debug APK and/or iOS simulator app, build host,
   command, log, and artifact checksum. This is compilation evidence only; it
   does not claim signing, installation, launch, or store readiness.
3. **Android emulator plugin smoke** — API level/device profile plus each
   camera/photo, notification, and file-picker observation below.
4. **iOS simulator plugin smoke** — iOS/runtime/device profile plus each plugin
   observation below.
5. **Physical-device plugin smoke** — optional, recorded separately by OS and
   hardware. Never infer it from a simulator result.
6. **Manual accessibility** — assistive technology, OS/runtime, text size,
   screen, focus/reading order, control names/roles/states, and result.

Use `Not run — <reason>` for unavailable simulator/device categories. A blank
cell or an automated fake is not device evidence. Do not include real names,
item notes, photos, exported backups, absolute private paths, or notification
contents in logs or release notes.

## Automated coverage

`make verify-rc` checks formatting, strict analysis, all unit/widget tests, the
headless lifecycle integration test, Android debug compilation, and—only on a
macOS host—an iOS simulator `--no-codesign` build. CI runs these as independent
jobs and retains useful logs, coverage, and unsigned build artifacts.

The automated tests cover:

- record handoff → fake notification schedule → return → CSV/ZIP export → clean
  restore, including event history and local-only notes;
- every committed database version via immutable seeded fixtures;
- photo-picker cancellation plus gallery/camera denial and restriction codes,
  notification denial/revocation and
  relaunch reconciliation, file-picker selection/cancellation, missing
  attachments, and rollback-safe local deletion;
- UTC instants across timezone-offset and DST boundaries;
- screen-reader semantics, traversal, minimum targets, and 2x text on the
  exchange list, handoff, details, and data/privacy screens.

## Real plugin smoke paths

Run on every available Android emulator and iOS simulator. Start from a clean,
disposable install with invented data. Record each result in its exact evidence
category.

### Photo adapter

1. Open **Record handoff**, choose **Add optional photo**, and select a
   disposable image. Verify a preview/status appears and the text record saves.
2. Cancel the picker; verify no attachment is added and text-only save works.
3. Deny access, retry, then revoke an earlier grant in system settings. Verify
   the app reports denial/restriction and existing records remain readable.
4. Delete the selected image only from the disposable app sandbox when tooling
   permits; reopen details and verify the missing-photo state does not hide the
   exchange. Do not use a personal photo.

The current production action opens the photo library rather than exposing a
camera-capture choice. The fake boundary also verifies camera denial/restriction
codes so a platform response cannot break the text-only flow, but that is not a
real camera smoke result. Record camera capture as `Not applicable — camera
source not exposed` unless a future build adds that explicit source.

### Notification adapter

Follow [notification-verification.md](notification-verification.md), including
first-use grant/deny, revoked permission, schedule over the local DST transition
when the runtime timezone supports one, app termination/relaunch reconciliation,
delivery tap, cancellation on return, and a stale tap after record deletion.

### File-picker adapter

1. Export CSV and ZIP to an explicitly selected disposable location; cancel
   each picker once and verify no success is claimed.
2. Restore the ZIP into a clean disposable install, inspect the preview, cancel,
   repeat, confirm, and verify history. Then select a non-ZIP/unreadable file and
   verify a safe failure without changing local records.
3. Remove/revoke the selected provider location where the simulator supports
   it and verify failure remains local and retryable.

## Manual TalkBack and VoiceOver

With TalkBack on Android and VoiceOver on iOS, visit **Exchanges**, **Record
handoff**, **Exchange details**, and **Data and privacy** at default and 2x/200%
text. Verify headings and status are announced, labels are not duplicated,
search/filter order is logical, selected direction/status and disabled/busy
states are exposed, destructive actions and confirmations are explicit, focus
returns predictably after dialogs/navigation, and every primary action remains
reachable without horizontal panning. Record observations separately for each
screen reader. No manual run is claimed by this document.
