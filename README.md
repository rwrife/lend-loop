# Lend Loop

**Local-first mobile app for households and hobby groups to track lent and borrowed items, due dates, returns, and portable history without accounts.**

> **Status:** the pinned Flutter mobile workspace and automated quality gates are in place. The app currently launches an honest “Under development” screen; exchange workflows and persistence are tracked in the issue backlog.

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

1. Photograph a drill, enter “Sam,” choose **Lent**, and set a return reminder for next Saturday.
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

Flutter provides one accessible UI codebase while retaining platform-native camera/photo-picker, file-share, and notification integrations. Domain and persistence logic will remain UI-independent and testable.

## Local data, export, and backup

The planned local database uses Drift over SQLite. Core entities are `PersonAlias`, `Item`, `Exchange`, `ExchangeEvent`, `Attachment`, and `Reminder`. Photos live in app-private storage and are referenced by stable attachment IDs rather than absolute paths.

- No account or remote service is required.
- A backup is a versioned ZIP containing a JSON manifest plus user-selected attachments.
- CSV export provides a human-readable exchange history without embedding photos.
- Restore validates schema version, attachment hashes, IDs, and required fields before changing local data.
- Deleting app data or uninstalling removes local records unless the user exported a backup.

## Privacy and permissions

Lend Loop is offline-first and does not include analytics, advertising, or remote synchronization in the MVP.

| Permission/capability | Default | Why |
|---|---:|---|
| Contacts | Not requested | People are entered as local aliases |
| Camera/photos | Optional, just in time | Add an item photo |
| Notifications | Optional, just in time | Schedule on-device due reminders |
| Location | Not requested | No location workflow |
| Network | Not required for core value | Development/package retrieval only |

The app remains useful if photo and notification permissions are denied. Export occurs only after an explicit user action through the platform share/file picker.

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

### Baseline dependency policy

The bootstrap has no third-party runtime packages: it uses only the BSD-3-Clause-licensed Flutter SDK. Test/lint dependencies are the Flutter SDK's `flutter_test` and BSD-3-Clause `flutter_lints` 6.0.0, with exact transitive versions committed in `pubspec.lock`. New packages require a license and privacy review before adoption.

## License

MIT. See [LICENSE](LICENSE).
