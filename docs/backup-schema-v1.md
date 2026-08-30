# Lend Loop backup schema v1

Lend Loop exports a UTF-8 `backup.json` document inside a ZIP archive. The top-level object is the stable interchange contract below. Timestamps are ISO-8601 UTC strings ending in `Z`; IDs are opaque, stable strings of 1–128 characters.

```json
{
  "format": "lend-loop-backup",
  "schemaVersion": 1,
  "exportedAt": "2026-08-28T12:30:00.000Z",
  "requiredFields": [
    "attachments",
    "events",
    "exchanges",
    "items",
    "people",
    "reminders"
  ],
  "people": [],
  "items": [],
  "exchanges": [],
  "events": [],
  "reminders": [],
  "attachments": []
}
```

## Collections

- `people`: `id`, `displayName`, nullable `privateNote`, `createdAt`, `updatedAt`.
- `items`: `id`, `name`, nullable `description`, nullable `category`, `createdAt`, `updatedAt`.
- `exchanges`: `id`, `itemId`, `personId`, `direction` (`lent` or `borrowed`), `handedOffAt`, nullable `dueAt`, `status` (`open` or `returned`), nullable `returnedAt`, `createdAt`, and `updatedAt`. Open exchanges have no `returnedAt`; returned exchanges require one. A due time cannot precede handoff.
- `events`: `id`, `exchangeId`, `type` (`created`, `edited`, `reminded`, `returned`, or `reopened`), `occurredAt`, and nullable `metadata`.
- `reminders`: `exchangeId`, `requestedAt`, `scheduledAt`, integer `platformSchedulingId`, `title`, `body`, and `deliveryState` (`pending` or `scheduled`). Restored reminder metadata is local desired state; the existing reconciliation path remains responsible for platform delivery.
- `attachments`: `id`, `exchangeId`, nullable `itemId`, portable `relativePath`, `mediaType`, `byteSize`, lowercase hexadecimal `sha256`, boolean `included`, and nullable `archivePath`.

When photos are included, each attachment payload is stored at `attachments/<attachment-id>/<file-name>` and `archivePath` names that entry. Record-only exports retain the manifest row but set `included` to `false` and `archivePath` to `null`. A photo that was already missing is represented the same way, so its text record remains portable.

## Validation and restore behavior

Restore fails closed before changing the database when the ZIP or JSON is malformed; a future schema version or unknown required collection is declared; a required field, linked row, or included file is absent; IDs or archive paths are duplicated; a timestamp, enum, status relationship, or due date is invalid; a path is absolute or contains traversal segments; or attachment size/SHA-256 verification fails. Undeclared ZIP entries are rejected.

Schema `0` record-only backups are migrated by treating absent reminders and attachments as empty collections. Future schema versions are not guessed at.

Preview classifies each incoming exchange as:

- **Add**: the stable exchange ID is not present locally.
- **Update**: the ID is present and the incoming `updatedAt` is newer.
- **Conflict**: the ID is present, differs, and is not newer. The local row wins.
- Identical rows are no-ops.

Only adds and updates are applied after explicit confirmation. Before restore, Lend Loop writes an app-private `backups/pre-restore-*.zip` snapshot of current records and available attachments. Database changes and attachment replacement/removal are performed while one SQLite transaction is open. If a file write or database operation fails, file changes are rolled back and the SQLite transaction is aborted, leaving the prior database and attachment files intact.

## CSV history

CSV export is UTF-8 with CRLF row endings and this header:

```text
exchange_id,direction,status,item,person,handoff_at,due_at,returned_at,notes
```

Fields containing commas, quotes, or line breaks follow RFC 4180 quoting rules. CSV is for inspection and spreadsheets; restore accepts only the versioned ZIP backup.

Both ZIP and CSV exports read their database rows from one SQLite transaction snapshot, so a concurrent local write cannot produce a mixture of old and new linked records.

## Privacy

MVP backups are **not encrypted**. Anyone who receives a ZIP can read its records and included photos. Export and restore begin only from explicit user actions and use the operating system file picker. Lend Loop does not upload backups, create accounts, add analytics or advertising, scrape contacts, or transfer records in the background.
