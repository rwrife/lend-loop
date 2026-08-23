# Lend Loop — Implementation Plan

## 1. Scope

Build a small Android/iOS application that records person-to-person item handoffs, shows what remains open, schedules optional local reminders, records returns, and exports/restores user-owned data. The MVP must deliver this workflow offline without an account, contact access, or a backend.

### Success criteria

A user can record and return an exchange in a few taps, understand every open obligation, deny every optional permission without losing the core workflow, and round-trip their records through a documented portable backup.

## 2. Architecture

Use a layered Flutter workspace:

```text
lib/
  app/             # routing, theme, dependency assembly
  domain/          # entities, value objects, policies, repository interfaces
  application/     # commands/queries and workflow orchestration
  data/            # Drift schema, migrations, file attachments, backup codec
  features/        # handoff, open list, details, history, settings
  platform/        # notifications, camera/photo picker, share/file picker

test/
  domain/
  application/
  data/
  features/

integration_test/
```

Dependencies point inward. Platform plugins are wrapped by narrow interfaces so domain and application tests require neither a device nor plugin channels.

## 3. Technology choices

- **Flutter/Dart:** one mobile UI codebase with mature Android/iOS accessibility and platform integration.
- **Drift + SQLite:** typed local queries and explicit, testable migrations.
- **Riverpod:** scoped dependency injection and predictable feature state without hiding persistence boundaries.
- **go_router:** declarative, testable navigation and deep-link-ready routes.
- **flutter_local_notifications:** local reminders only, behind an adapter.
- **image_picker:** camera/gallery selection only after explicit user action.
- **archive + cryptographic hash package:** deterministic versioned backup ZIP and attachment-integrity validation. MVP backups are not encrypted; the UI must state that clearly and let users omit attachments.
- **intl:** locale-aware dates and accessible text; no custom date arithmetic for due-state rules.

Package selections remain provisional until issue #1 pins supported versions and license compatibility.

## 4. Domain and local data model

- `PersonAlias`: id, display name, optional private note, created/updated timestamps
- `Item`: id, name, optional description/category, created/updated timestamps
- `Exchange`: id, item/person IDs, direction, handoff time, optional due time, status
- `ExchangeEvent`: append-only event type/time/metadata for created, edited, reminded, returned, reopened
- `Attachment`: id, exchange/item association, relative path, media type, byte size, digest
- `Reminder`: exchange ID, requested time, platform scheduling ID, current state

Repository writes are transactional. A return appends an event and updates the exchange projection atomically. UI undo issues a compensating reopen event rather than deleting history.

## 5. Milestones and dependency order

### M1 — Skeleton and quality gates

Create the Flutter project, analysis rules, formatting check, unit/widget test harness, Android/iOS configurations, and CI. Establish domain/application/data boundaries before feature work.

### M2 — Domain and persistence

Implement entities, direction/status/due-state policies, Drift schema, repository queries, migrations, and deterministic clocks/IDs for tests.

### M3 — Primary handoff and return workflow

Build open-exchange list, record-handoff form, exchange details, mark-returned action, validation, empty/error states, and undo semantics.

### M4 — Reminders, search, and accessibility

Add just-in-time notification permission, scheduling/reconciliation, person and text search, status filters, dynamic text, semantic labels, focus order, and high-contrast status treatment.

### M5 — Backup, restore, and privacy controls

Define a versioned export contract, generate JSON/CSV/ZIP exports, validate and preview restore, add deletion controls, document attachment/privacy behavior, and test corrupt/foreign-version inputs.

### M6 — Packaging and release

Run pinned analysis/tests, produce debug and release-candidate Android/iOS builds where signing permits, document signing/store steps, create screenshots only from real builds, and publish a reproducible tagged release checklist.

## 6. Testing strategy

- **Unit tests:** due-state boundaries, direction wording, event transitions, validation, migration transforms, backup codecs, digest checks
- **Repository tests:** in-memory SQLite transactions, filters, sorting, migration fixtures, return/reopen consistency
- **Widget tests:** handoff form, open list, detail/return flow, denied permissions, empty/error states, large text, semantics
- **Integration tests:** record → remind-adapter request → return → export → clean restore round trip
- **Platform smoke tests:** notification scheduling/cancellation and photo/file picker behavior on Android and iOS simulators/devices when available
- **Property/fuzz tests:** malformed backup manifests, duplicate IDs, invalid paths, missing attachments, unknown schema versions

Static analysis, automated tests, simulator checks, and physical-device checks must be reported separately. A simulator run is not physical-device verification.

## 7. Packaging and distribution

- Pin Flutter and Dart versions in CI and developer metadata.
- Build Android APK/AAB and iOS archive through reproducible scripts.
- Keep signing credentials outside Git; CI release signing is optional and separately configured.
- Start with GitHub Releases for Android test artifacts and documented iOS local/TestFlight steps.
- Store metadata must accurately disclose optional camera/photo and notification usage, offline storage, and no account requirement.
- No package or store availability is claimed until a real build and publication occurs.

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Notification permission denied or schedules evicted | Core open/due views remain complete; reconcile scheduled IDs on launch |
| Time zone or daylight-saving transitions | Store instants plus relevant local context; centralize due-state tests around transitions |
| Restore overwrites good data | Validate and preview first; create a pre-restore local snapshot; use one transaction |
| Missing/moved attachments | Stable relative IDs, hashes, explicit missing-file state, no broken absolute paths |
| Sensitive person/item details in export | Explicit export action, clear warning, attachment opt-out, no automatic sharing |
| Plugin behavior differs by platform | Adapters, fakes, simulator checks, and later real-device evidence |
| Scope expands into inventory or messaging | Keep item metadata minimal and exclude chat, contact sync, payments, and cloud accounts |

## 9. Explicit non-goals

- Cloud sync, collaborative accounts, or a hosted API
- Automated SMS/email reminders to other people
- Contact-book import in the MVP
- Payments, deposits, contracts, collections, or legal evidence
- Business barcode checkout and fleet asset management
- Geofencing, Bluetooth trackers, or background location
- AI-generated item recognition or valuation

## 10. Data ownership and permissions checklist

- Local database and app-private attachment directory documented
- JSON/CSV/ZIP formats versioned and tested
- User-triggered export and restore only
- Camera/photos and notification permissions requested in context
- Core record/return flow works with all optional permissions denied
- Clear “delete all local data” confirmation and outcome
- No analytics, ads, account, background location, or contacts permission in MVP
