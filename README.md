# Lend Loop

**Local-first mobile app for households and hobby groups to track lent and borrowed items, due dates, returns, and portable history without accounts.**

> **Status:** documentation and backlog scaffold only. The Flutter project, application builds, automated tests, and store packages have not been created yet.

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

## Development quickstart

The repository does not contain a Flutter project yet. After the skeleton milestone lands, the expected developer flow will be:

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

Exact Flutter/Dart versions will be pinned in the project and CI rather than implied by this scaffold. Until then, these commands are planned interfaces, not verified build evidence.

## License

MIT. See [LICENSE](LICENSE).
