# Changelog

All notable user-visible changes are recorded here. Lend Loop uses semantic
application versions and separate release-candidate tags.

## [0.1.0-rc.1] - 2026-09-01

### Added

- Offline lent/borrowed handoff records with local person aliases, optional due
  dates, notes, and user-selected photos.
- Open, due, overdue, returned, search, and filter views.
- Atomic return/reopen history with a timed undo action.
- Optional on-device reminders requested only from the reminder action.
- Versioned ZIP backup/restore, UTF-8 CSV history export, restore preview, and
  local photo/exchange/delete-all controls.
- Repeatable headless verification commands and unsigned Android/iOS
  release-candidate packaging with toolchain evidence, logs, and verified
  SHA-256 manifests.

### Privacy

- No account, analytics, advertising, contacts access, cloud backend, or hidden
  data transfer.
- Photos and notifications remain optional; the record and return workflow is
  useful when either permission is denied.

### Distribution status

This is a GitHub prerelease candidate, not an App Store or Google Play
publication. Published CI artifacts are explicitly labeled debug, simulator,
or unsigned and are not evidence of store signing or physical-device testing.
