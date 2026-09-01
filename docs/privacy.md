# Privacy and permissions

## Local-first contract

Lend Loop stores its SQLite database, selected-photo copies, reminder metadata,
and automatic pre-restore snapshots inside the app sandbox. It has no account,
analytics, ads, cloud backend, contact scraping, location tracking, background
backup, or hidden data transfer. Core record, search, return/reopen, and export
behavior does not require network access.

The platform and package managers may use a network while developers build the
app or while a user obtains it from a distribution service; that is not app
runtime synchronization.

## Data handled

| Data | Where/why | Leaves the device? |
|---|---|---|
| Item names, person aliases, dates, notes, and event history | Local SQLite database | Only through an explicit export selected by the user |
| Optional photos | Copied to app-private storage; relative path and SHA-256 metadata in SQLite | Only when the user exports a ZIP with photos enabled |
| Reminder title/body and schedule | Local database plus the operating system notification scheduler | Sent only to the device scheduler, not a Lend Loop server |
| ZIP/CSV exports | Destination selected in the system file picker | Only to the user-selected provider/location |
| Pre-restore snapshot | App-private storage for rollback/recovery safety | No automatic transfer |

ZIP backups are not encrypted. Anyone with the file can read its records and
included photos. CSV exports contain record history and are not restorable.

## Permission/capability declarations

| Permission/capability | Request point | Behavior when denied |
|---|---|---|
| Photo library | After **Add optional photo** | Save and use a text-only exchange |
| Notifications | When enabling the first due reminder | Keep all records, due states, editing, return, and export behavior |
| System file picker | After an explicit export or restore action | Cancel/failure leaves records unchanged and does not claim success |
| Contacts | Never requested | People remain user-entered local aliases |
| Location | Never requested | No location feature |
| Camera capture | Not exposed in this release candidate | Photo-library selection remains optional |

Android declares notification delivery and boot-reconciliation capabilities;
notification permission is still requested just in time by the reminder action.
iOS includes a photo-library purpose string. File selection uses operating
system pickers and does not grant Lend Loop broad background access.

## Deletion and retention

Users can remove one photo while keeping a text record, delete an exchange and
its history, or delete all app-local data. Deleting or uninstalling the app can
make records unrecoverable unless the user explicitly saved a backup elsewhere.
Lend Loop has no server-side copy to retain or recover.

## Store disclosure baseline

The matching concise store answers and reviewer notes are in
[`store-metadata.md`](store-metadata.md). They must be rechecked against the
exact submitted binary and current store questionnaires before publication.
