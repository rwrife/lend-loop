# Lend Loop user guide

Lend Loop keeps lending and borrowing records on your device. There is no
account to create and no contacts import. Use a made-up record first if you are
evaluating a release candidate.

## Record a handoff

1. From **Exchanges**, choose **Record handoff**.
2. Select **Lent** when another person has your item or **Borrowed** when you
   have theirs.
3. Enter an item name and a person alias. Notes and a due date are optional;
   the due date cannot be earlier than the handoff date.
4. Optional: choose **Add optional photo**. Lend Loop opens the platform photo
   picker only after this action and copies the selected image into app-private
   storage. Canceling or denying photo access leaves the form usable.
5. Choose **Save handoff**. A storage error is shown instead of silently losing
   the record.

## Find a record

The app opens to open exchanges. Search item names, person aliases, or notes;
filter by person, lent/borrowed direction, open/returned status, or handoff date.
Due and overdue states are written in text and are not conveyed by color alone.
Select a row to see its dates, notes, photo state, reminder action, and history.

## Optional reminders and permission denial

For an open, not-overdue exchange with a due date, open its details and choose
**Enable due reminder**. Notification permission is requested only when the
first reminder is enabled. If access is denied or later revoked, the exchange,
due-state list, editing, return, and export features continue to work. You can
retry pending reminder delivery from the details screen. Marking an exchange
returned cancels its persisted reminder intent; startup reconciliation retries
platform cleanup when needed.

## Return, undo, and reopen

Open an exchange and choose **Mark returned**. The app updates the record and
appends its history atomically. **Undo** is available in the confirmation bar
for six seconds. Later, select **Returned** (or **All history**), open the
record, and choose **Reopen exchange**. Reopening adds another history event; it
does not erase the return.

## Export your data

Open **Data and privacy** from the shield button in the Exchanges app bar.

- **Export ZIP backup** creates a restorable, versioned backup. **Include photos
  in ZIP backup** is on by default; turn it off for a record-only backup.
- **Export CSV history** creates human-readable UTF-8 rows for inspection. CSV
  files cannot be restored.
- The system file picker appears only after an export action. Canceling it does
  not report success or upload anything.

Backups are not encrypted. Anyone who obtains a ZIP can read its records and
included photos. Store and share it only where you trust. Lend Loop never
uploads a backup on its own.

## Preview and restore

1. From **Data and privacy**, choose **Preview and restore ZIP** and select a
   Lend Loop ZIP backup.
2. Review the add, update, conflict, and missing-photo counts. Nothing changes
   during preview. Conflicts keep the local record when the backup is not newer.
3. Choose **Restore** to continue or **Cancel** to leave local data unchanged.

Before applying an approved restore, Lend Loop creates an app-private snapshot.
Malformed, future-version, path-unsafe, duplicate, undeclared, or hash-mismatched
content is rejected. A failed restore rolls database and file changes back.

## Delete photos, records, or everything

- In exchange details, **Delete photo** removes the local photo while keeping
  the text record and history.
- **Delete exchange** removes that exchange, its complete history, reminder,
  and attachments from this device after confirmation.
- **Delete all local data** under **Data and privacy** removes every exchange,
  history event, reminder, app-private attachment, and automatic pre-restore
  snapshot after confirmation.

Export a backup first if you may need the data later. There is no account or
cloud copy to recover deleted data. If the operating system cannot finish file
or notification cleanup, the app reports the partial cleanup rather than
claiming that everything was removed.
