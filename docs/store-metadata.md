# Store metadata baseline

This file is release-review input, not proof of App Store or Google Play
publication. Store forms change; answer the current forms from the exact binary.

## Short description

Privately track items you lend and borrow, due dates, returns, reminders, and
portable backups—without an account.

## Privacy summary

- Records and optional photos are stored locally in the app sandbox.
- No account, analytics, advertising, cloud sync, contact access, location, or
  background data transfer.
- A user may explicitly export unencrypted ZIP backups (with optional photos)
  or UTF-8 CSV history through the system file picker.
- Optional local notifications contain an item and person alias and are sent to
  the operating system notification scheduler, not to a Lend Loop server.
- The app does not collect data for tracking, advertising, profiling, or sale.

## Permission copy

- **Photos:** “Add an optional item photo to a private local handoff record.”
  Access begins only after **Add optional photo**. Denial preserves the full
  text-only workflow.
- **Notifications:** Used only after the user chooses **Enable due reminder**.
  Denial preserves open/due views and every non-notification feature.
- **Contacts/location:** not requested.
- **Camera:** capture is not exposed in this release candidate.

## Reviewer notes

The app opens directly to **Exchanges** with no login. Create an invented
handoff, optionally deny photo and notification access, mark it returned, undo
or reopen it, then open the shield button for export/restore/deletion. Backups
are explicitly labeled unencrypted. No review account or backend is required.

## Publication claims

`v0.1.0-rc.1` is a GitHub prerelease candidate. Do not mark App Store or Google
Play availability, TestFlight review, signed-device installation, screenshots,
or physical-device checks complete unless separately performed and recorded.
