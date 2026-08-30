# Lend Loop

**Local-first mobile app for households and hobby groups to track lent and borrowed items, due dates, returns, and portable history without accounts.**

> **Status:** the complete local handoff, return/reopen, reminder, portable backup/restore, CSV export, and deletion workflow is implemented without accounts or hidden data transfer.

## Overview

Lend Loop answers two ordinary questions: **“Who has my item?”** and **“What do I need to return?”** A user records an item at handoff, identifies the other person with a locally stored display name, optionally adds a photo and due date, and later marks the exchange returned. The useful core works entirely offline and without registration.

## Motivation

Tools, books, games, sports gear, cables, and household equipment often move between friends, neighbors, club members, and family. Generic notes lose the relationship between item, person, direction, due date, and return. Full inventory systems are too heavy and often assume a business checkout desk or cloud account.

Lend Loop focuses on a private, fast handoff-and-return loop rather than cataloging everything a person owns.

## Target users

- Households sharing or lending equipment
- Hobby, maker, and recreational-sport groups
- Neighbors who exchange tools, books, games, or supplies
- Individuals who want a private record of both lent and borrowed items

## Concrete use cases

1. Select a drill photo, enter “Sam,” choose **Lent**, and set a due date for next Saturday.
2. Record a library book borrowed from a friend without granting contacts access.
3. Filter open exchanges by person before a club meeting.
4. Mark one or several items returned while preserving a dated history.
5. Export all records and photos before moving phones, then restore them on another device.

## Intended end-to-end workflow

1. Open directly to **Open exchanges**; no sign-in or onboarding account is required.
2. Tap **Record handoff** and choose **Lent** or **Borrowed**.
3. Enter the item and person display names; optionally add notes, a photo, handoff date, and due date.
4. Review the summary and save locally.
5. Receive an optional on-device reminder. Lend Loop never sends a message to another person on the user's behalf.
6. Open the exchange, postpone its reminder if needed, or mark it returned.
7. Search/filter history or export a portable backup.

## Implemented record and return workflow

The app now opens directly to **Exchanges** with **All open**, **Due soon**, **Overdue**, and **Returned** filters, so a previously returned record remains reachable for an explicit later reopen. A handoff records its lent/borrowed direction, item name, local person alias, handoff date, optional due date, and optional notes. Required fields and inconsistent dates are reported inline. List and detail wording always says “You lent … to …” or “You borrowed … from …”; direction and due state are never communicated by color or an icon alone.

**Add optional photo** is an explicit, just-in-time photo-library action behind a platform adapter. A selected image is copied into the app-private attachment directory, SHA-256 hashed, and referenced by a portable relative path. Cancellation or denied photo access leaves the form and the saved text-only record fully usable. If a referenced image is later missing, details show a missing-photo message without hiding the record. Lend Loop does not request contacts, location, notification, or network access for this workflow.

Marking an exchange returned atomically appends a `returned` event and updates the projection. A six-second snackbar offers **Undo**, which appends a compensating `reopened` event; returned details also expose an explicit **Reopen exchange** action. History is preserved rather than rewritten. Empty, loading, validation, missing-photo, database-open, list-load, and save-error states provide explicit text.

## MVP features

- Lent and borrowed exchange records
- Open, due soon, overdue, and returned views
- Locally stored people aliases—no contacts permission required
- Optional item photo captured or selected with explicit permission
- Optional on-device due reminders
- Return action with immutable event history and undo window
- Person, direction, status, and text filters
- Versioned JSON backup/restore and CSV history export
- Dark mode, dynamic text, keyboard access where supported, and screen-reader labels

## Non-goals

- Business asset management, deposits, payments, or legal contracts
- Social accounts, public profiles, messaging, or collection activity
- Automatic contact scraping or background location tracking
- Cloud sync in the MVP
- Valuation, insurance, proof-of-ownership, or dispute resolution
- Barcode-based retail inventory management

## Platforms and framework

- **Framework:** Flutter with Dart
- **Initial targets:** Android 10+ and iOS 16+
- **Desktop/web:** not part of the MVP; portable exports remain readable without the app

Flutter provides one accessible UI codebase while retaining platform-native photo, file-picker, and notification integrations. Domain and persistence logic remains UI-independent and testable.

## Local data and persistence

The implemented schema uses Drift over SQLite for `PersonAlias`, `Item`, `Exchange`, append-only `ExchangeEvent`, `Attachment`, and `Reminder` records. It stores UTC instants as SQLite integer timestamps. Exchange direction is `lent` or `borrowed`; status is `open` or `returned`. A returned projection must have a return timestamp and an open projection must not. Due times cannot precede handoff times.

Create and edit produce history events. Return and reopen append a compensating event and update the exchange projection in one SQLite transaction; stale or mismatched transitions are rejected, and failed writes roll back both changes. Creating another exchange can safely reuse existing person/item IDs while updating their mutable labels and preserving original creation timestamps. Repository queries support status, due cutoff, person, direction, and case-insensitive item/person text filters, with due-dated results ordered earliest first and records without due dates last. Database schema version 3 preserves valid version 1/2 history while rebuilding integrity constraints and durable reminder state; invalid legacy rows fail migration without being silently accepted.

Attachments contain a stable ID and a portable path relative to an app-owned storage root. Domain validation and a database constraint reject Unix, Windows-drive, and parent-traversal paths. No device-specific path is persisted. The application-support root is resolved to its canonical operating-system path, the supplied root itself must be a real directory rather than a link, and every app-relative component is checked for symbolic links at filesystem operation boundaries. App-controlled photo, backup, restore, and cleanup operations are serialized. This containment model relies on the supported Android/iOS app sandbox preventing an adversarial external process from rewriting private paths between a pure-Dart check and syscall; pure Dart cannot make those two actions atomic.

Users can delete a photo while retaining its text exchange, delete an individual exchange and its history, or delete all local records, attachments, reminders, and automatic pre-restore snapshots after a destructive confirmation. Photo, exchange, and all-data deletion first moves known files to private deletion staging, rolls them back if the database deletion fails, and removes (or retries) staged files only after commit; all-data deletion then sweeps unreferenced private attachment and staging files. If post-commit operating-system file or notification cleanup fails, the app reports that partial cleanup instead of falsely claiming rollback.

Open **Data and privacy** from the Exchanges app bar to use explicit system file-picker actions:

- **Export ZIP backup** writes the versioned `backup.json` manifest and, when the **Include photos** switch is on, verified attachment payloads. Turn it off for a record-only backup.
- **Export CSV history** writes documented UTF-8 exchange rows without photos. CSV is inspection-only and cannot be restored.
- **Preview and restore ZIP** validates the complete archive before showing add/update/conflict/missing-photo counts. Nothing changes until confirmation. Newer incoming rows are added or updated; same-age/older conflicts retain the local row.
- Immediately before an approved restore, the app creates an app-private pre-restore ZIP snapshot. Adds, updates, and attachment replacement/removal run while one SQLite transaction is open; file changes are explicitly rolled back if any file or database operation fails, and the database transaction is aborted.
- Unsupported future versions, unknown required collections, duplicate IDs/paths, malformed timestamps, invalid relationships, traversal paths, undeclared files, and attachment size/SHA-256 mismatches are rejected.

The full stable field contract, schema-0 migration, validation rules, merge policy, and CSV format are published in [docs/backup-schema-v1.md](docs/backup-schema-v1.md). Backups are **not encrypted**: anyone with the file can read its records and included photos. Lend Loop never uploads them. Deleting app data or uninstalling removes local records unless the user explicitly saved a backup elsewhere.

## Privacy and permissions

Lend Loop is offline-first and does not include analytics, advertising, or remote synchronization in the MVP.

| Permission/capability | Default | Why |
|---|---:|---|
| Contacts | Not requested | People are entered as local aliases |
| Photo library | Optional, just in time | Add an item photo after tapping the photo action |
| Notifications | Optional, just in time | Schedule on-device due reminders |
| Location | Not requested | No location workflow |
| Network | Not required for core value | Development/package retrieval only |

The app remains useful if photo and notification permissions are denied. Export and restore occur only after explicit user actions through the platform file picker. No account, analytics, ads, contacts access, cloud backend, or background backup transfer is present.

## Accessibility expectations

- Complete screen-reader names, roles, values, and hints for interactive controls
- Logical focus order and no color-only status communication
- Support for large text without clipped primary actions
- Minimum 44×44 pt / 48×48 dp touch targets
- High-contrast status icons and text labels
- Reduced-motion-safe transitions
- Keyboard navigation for tablets and hardware keyboards where Flutter supports it
- Date and direction phrasing that is understandable without icons

## Milestones

1. Flutter skeleton, CI, and architectural boundaries
2. Local exchange domain and persistence
3. Record/return primary workflow
4. Accessible reminders, search, and history
5. Backup/restore and privacy controls
6. Platform builds and release preparation

See [PLAN.md](PLAN.md) and the GitHub issue backlog for dependency order and acceptance criteria.

## Workspace architecture

The Flutter source follows inward dependency boundaries:

```text
lib/
  app/             # application shell, theme, and dependency assembly
  domain/          # UI-independent entities, policies, and interfaces
  application/     # commands, queries, and workflow orchestration
  data/            # Drift repositories, migrations, attachments, backups
  features/        # screens and feature presentation
  platform/        # narrow adapters around optional platform capabilities

test/
  app/ domain/ application/ data/ features/
integration_test/
```

Boundary README files reserve later milestones without shipping placeholder Dart implementations. Platform plugins must remain behind narrow interfaces, and optional permissions must be requested only from the feature that needs them.

## Development quickstart

### Pinned toolchain

- Flutter **3.47.1** (stable), recorded in [`.flutter-version`](.flutter-version)
- Dart **3.13.1** (bundled with that Flutter release)
- Android minimum: **Android 10 / API 29**
- iOS minimum: **iOS 16.0**

Install the exact SDK from the official Flutter repository and verify it before resolving packages:

```bash
git clone https://github.com/flutter/flutter.git \
  --branch 3.47.1 --depth 1 "$HOME/flutter-3.47.1"
export PATH="$HOME/flutter-3.47.1/bin:$PATH"
flutter --version
flutter pub get --enforce-lockfile
```

Run the same quality gates as CI:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test --coverage
```

Run or build the supported platforms:

```bash
flutter run
flutter build apk --debug
# macOS with Xcode only; this verifies an unsigned simulator build.
flutter build ios --simulator --no-codesign
```

CI resolves the committed lockfile from a clean checkout, checks formatting, runs strict static analysis and automated unit/widget tests, then builds an Android debug APK and unsigned iOS simulator app. An iOS simulator build is not App Store signing or physical-device evidence.

### Dependencies, licenses, and generated code

Runtime persistence uses `drift` 2.34.3 (MIT) and `sqlite3` 3.5.2 (MIT, with native binaries supplied through Dart build hooks); SQLite itself is public domain. `path_provider` 2.1.6 locates app-private storage, `image_picker` 1.2.3 performs only the user-triggered photo selection, `flutter_local_notifications` 19.4.2 schedules optional on-device reminders, `timezone` 0.10.1 represents their UTC instants, `crypto` 3.0.7 computes attachment SHA-256 digests, `archive` 4.2.0 writes/validates ZIP files, and `file_picker` 12.1.2 provides user-initiated save/open dialogs. These dependencies do not add accounts, analytics, advertising, cloud synchronization, contacts, or hidden data transfer. Flutter remains BSD-3-Clause. Development-only generation uses `drift_dev` 2.34.5 and `build_runner` 2.16.0; lint/test tooling remains `flutter_lints` 6.0.0 and `flutter_test`. Exact direct and transitive versions are committed in `pubspec.lock`.

Notification platform declarations, automated coverage, and an honest manual verification checklist are documented in [docs/notification-verification.md](docs/notification-verification.md). No simulator or physical-device verification is implied by automated tests.

Generated Drift source is committed. Reproduce it with the pinned SDK:

```bash
dart run build_runner build
```

Application startup opens `lend_loop.sqlite` in the platform application-support directory. Startup failures display an honest local-storage error instead of silently substituting an empty database. The exchange workflow receives the concrete repository, clock, ID generator, and photo adapter through dependency injection, while tests use in-memory SQLite and adapter fakes.

## License

MIT. See [LICENSE](LICENSE).
