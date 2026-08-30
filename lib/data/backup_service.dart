import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/private_storage.dart';

const int currentBackupSchemaVersion = 1;
const String backupSchemaFile = 'backup.json';
const int _maxCompressedBackupBytes = 512 * 1024 * 1024;
const int _maxExpandedBackupBytes = 1024 * 1024 * 1024;
const int _maxArchiveEntries = 10000;
const int _maxEntryBytes = 100 * 1024 * 1024;
const int _maxManifestBytes = 16 * 1024 * 1024;
const Set<String> _requiredCollections = <String>{
  'people',
  'items',
  'exchanges',
  'events',
  'reminders',
  'attachments',
};

typedef BackupRootDirectoryProvider = Future<Directory> Function();

final class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => 'BackupException: $message';
}

final class BackupArtifact {
  const BackupArtifact({required this.fileName, required this.bytes});
  final String fileName;
  final Uint8List bytes;
}

final class RestorePreview {
  const RestorePreview._(
    this._parsed,
    this._applicableExchangeIds,
    this._expectedLocalVersions, {
    required this.adds,
    required this.updates,
    required this.conflicts,
    required this.missingAttachments,
  });

  final int adds;
  final int updates;
  final int conflicts;
  final int missingAttachments;
  final _ParsedBackup _parsed;
  final Set<String> _applicableExchangeIds;
  final Map<String, int?> _expectedLocalVersions;
}

final class RestoreResult {
  const RestoreResult({
    required this.added,
    required this.updated,
    required this.conflictsKept,
    required this.preRestoreSnapshotPath,
  });
  final int added;
  final int updated;
  final int conflictsKept;
  final String preRestoreSnapshotPath;
}

final class BackupService {
  const BackupService({
    required this.database,
    required this.rootDirectory,
    required this.clock,
    this.beforeRestoreCommit,
    this.afterFirstSnapshotRead,
    this.beforeFileBoundary,
  });

  final LendLoopDatabase database;
  final BackupRootDirectoryProvider rootDirectory;
  final Clock clock;

  /// Test seam invoked inside the restore transaction before any commit.
  final Future<void> Function()? beforeRestoreCommit;

  /// Test seam invoked after the first read in an export transaction.
  final Future<void> Function()? afterFirstSnapshotRead;

  /// Deterministic seam used to verify operation-boundary revalidation.
  final Future<void> Function()? beforeFileBoundary;

  Future<BackupArtifact> createCsvExport() async {
    final (List<ExchangeRow>, List<PersonRow>, List<ItemRow>) snapshot =
        await database.transaction(() async {
          final List<ExchangeRow> exchanges = await database
              .select(database.exchanges)
              .get();
          await afterFirstSnapshotRead?.call();
          return (
            exchanges,
            await database.select(database.people).get(),
            await database.select(database.items).get(),
          );
        });
    final List<ExchangeRow> exchanges = snapshot.$1;
    final Map<String, PersonRow> people = <String, PersonRow>{
      for (final PersonRow row in snapshot.$2) row.id: row,
    };
    final Map<String, ItemRow> items = <String, ItemRow>{
      for (final ItemRow row in snapshot.$3) row.id: row,
    };
    exchanges.sort((ExchangeRow a, ExchangeRow b) {
      final int time = a.handedOffAt.compareTo(b.handedOffAt);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
    final StringBuffer csv = StringBuffer(
      'exchange_id,direction,status,item,person,handoff_at,due_at,returned_at,notes\r\n',
    );
    for (final ExchangeRow exchange in exchanges) {
      final PersonRow? person = people[exchange.personId];
      final ItemRow? item = items[exchange.itemId];
      if (person == null || item == null) {
        throw const BackupException('An exchange has missing linked data.');
      }
      csv.write(
        <Object?>[
          exchange.id,
          exchange.direction,
          exchange.status,
          item.name,
          person.displayName,
          _timestamp(exchange.handedOffAt),
          exchange.dueAt == null ? null : _timestamp(exchange.dueAt!),
          exchange.returnedAt == null ? null : _timestamp(exchange.returnedAt!),
          item.description,
        ].map(_csvCell).join(','),
      );
      csv.write('\r\n');
    }
    return BackupArtifact(
      fileName: 'lend-loop-history-${_fileTimestamp(clock.now())}.csv',
      bytes: Uint8List.fromList(utf8.encode(csv.toString())),
    );
  }

  Future<BackupArtifact> createBackup({required bool includeAttachments}) =>
      withPrivateStorage(
        rootDirectory,
        (Directory root, PrivateStorageBoundary revalidate) => _createBackup(
          root,
          revalidate,
          includeAttachments: includeAttachments,
        ),
      );

  Future<BackupArtifact> _createBackup(
    Directory root,
    PrivateStorageBoundary revalidate, {
    required bool includeAttachments,
  }) async {
    final (
      List<PersonRow>,
      List<ItemRow>,
      List<ExchangeRow>,
      List<ExchangeEventRow>,
      List<ReminderRow>,
      List<AttachmentRow>,
    )
    snapshot = await database.transaction(() async {
      final List<PersonRow> people = await database
          .select(database.people)
          .get();
      await afterFirstSnapshotRead?.call();
      return (
        people,
        await database.select(database.items).get(),
        await database.select(database.exchanges).get(),
        await database.select(database.exchangeEvents).get(),
        await database.select(database.reminders).get(),
        await database.select(database.attachments).get(),
      );
    });
    final List<PersonRow> people = snapshot.$1;
    final List<ItemRow> items = snapshot.$2;
    final List<ExchangeRow> exchanges = snapshot.$3;
    final List<ExchangeEventRow> events = snapshot.$4;
    final List<ReminderRow> reminders = snapshot.$5;
    final List<AttachmentRow> attachments = snapshot.$6;

    people.sort((PersonRow a, PersonRow b) => a.id.compareTo(b.id));
    items.sort((ItemRow a, ItemRow b) => a.id.compareTo(b.id));
    exchanges.sort((ExchangeRow a, ExchangeRow b) => a.id.compareTo(b.id));
    events.sort(
      (ExchangeEventRow a, ExchangeEventRow b) => a.id.compareTo(b.id),
    );
    reminders.sort(
      (ReminderRow a, ReminderRow b) => a.exchangeId.compareTo(b.exchangeId),
    );
    attachments.sort(
      (AttachmentRow a, AttachmentRow b) => a.id.compareTo(b.id),
    );

    final Archive archive = Archive();
    final List<Map<String, Object?>> attachmentManifest =
        <Map<String, Object?>>[];
    for (final AttachmentRow attachment in attachments) {
      await beforeFileBoundary?.call();
      await revalidate();
      final String relativePath = validateRelativePath(attachment.relativePath);
      final File source = await _containedFile(root, relativePath);
      Uint8List? bytes;
      String? archivePath;
      if (includeAttachments && await source.exists()) {
        bytes = await source.readAsBytes();
        if (bytes.length > _maxEntryBytes) {
          throw BackupException(
            'Attachment ${attachment.id} exceeds the backup size limit.',
          );
        }
        final String digest = sha256.convert(bytes).toString();
        if (bytes.length != attachment.byteSize ||
            digest != attachment.digest) {
          throw BackupException(
            'Attachment ${attachment.id} does not match its stored size and hash.',
          );
        }
        archivePath = validateRelativePath(
          'attachments/${attachment.id}/${relativePath.split('/').last}',
        );
        archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
      }
      attachmentManifest.add(<String, Object?>{
        'id': attachment.id,
        'exchangeId': attachment.exchangeId,
        'itemId': attachment.itemId,
        'relativePath': relativePath,
        'mediaType': attachment.mediaType,
        'byteSize': attachment.byteSize,
        'sha256': attachment.digest,
        'included': bytes != null,
        'archivePath': archivePath,
      });
    }

    final Map<String, Object?> manifest = <String, Object?>{
      'format': 'lend-loop-backup',
      'schemaVersion': currentBackupSchemaVersion,
      'exportedAt': _timestamp(clock.now()),
      'requiredFields': _requiredCollections.toList()..sort(),
      'people': people
          .map(
            (PersonRow row) => <String, Object?>{
              'id': row.id,
              'displayName': row.displayName,
              'privateNote': row.privateNote,
              'createdAt': _timestamp(row.createdAt),
              'updatedAt': _timestamp(row.updatedAt),
            },
          )
          .toList(),
      'items': items
          .map(
            (ItemRow row) => <String, Object?>{
              'id': row.id,
              'name': row.name,
              'description': row.description,
              'category': row.category,
              'createdAt': _timestamp(row.createdAt),
              'updatedAt': _timestamp(row.updatedAt),
            },
          )
          .toList(),
      'exchanges': exchanges.map(_exchangeMap).toList(),
      'events': events
          .map(
            (ExchangeEventRow row) => <String, Object?>{
              'id': row.id,
              'exchangeId': row.exchangeId,
              'type': row.type,
              'occurredAt': _timestamp(row.occurredAt),
              'metadata': row.metadata,
            },
          )
          .toList(),
      'reminders': reminders
          .map(
            (ReminderRow row) => <String, Object?>{
              'exchangeId': row.exchangeId,
              'requestedAt': _timestamp(row.requestedAt),
              'scheduledAt': _timestamp(row.scheduledAt),
              'platformSchedulingId': row.platformSchedulingId,
              'title': row.title,
              'body': row.body,
              'deliveryState': row.deliveryState,
            },
          )
          .toList(),
      'attachments': attachmentManifest,
    };
    final Uint8List json = Uint8List.fromList(
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(manifest)}\n'),
    );
    archive.addFile(ArchiveFile(backupSchemaFile, json.length, json));
    final Uint8List encoded = Uint8List.fromList(ZipEncoder().encode(archive));
    return BackupArtifact(
      fileName: 'lend-loop-backup-${_fileTimestamp(clock.now())}.zip',
      bytes: encoded,
    );
  }

  Future<RestorePreview> previewRestore(Uint8List bytes) async {
    final _ParsedBackup parsed = _parse(bytes);
    final List<ExchangeRow> existingRows = await database
        .select(database.exchanges)
        .get();
    final Map<String, ExchangeRow> existing = <String, ExchangeRow>{
      for (final ExchangeRow row in existingRows) row.id: row,
    };
    final Map<String, PersonRow> existingPeople = <String, PersonRow>{
      for (final PersonRow row in await database.select(database.people).get())
        row.id: row,
    };
    final Map<String, ItemRow> existingItems = <String, ItemRow>{
      for (final ItemRow row in await database.select(database.items).get())
        row.id: row,
    };
    int adds = 0;
    int updates = 0;
    int conflicts = 0;
    final Set<String> applicable = <String>{};
    final Set<String> additions = <String>{};
    for (final Map<String, Object?> incoming in parsed.exchanges) {
      final String id = incoming['id']! as String;
      final ExchangeRow? local = existing[id];
      if (local == null) {
        adds += 1;
        applicable.add(id);
        additions.add(id);
        continue;
      }
      if (_sameMap(_exchangeMap(local), incoming)) continue;
      final DateTime incomingUpdated = _date(incoming, 'updatedAt');
      if (incomingUpdated.isAfter(local.updatedAt)) {
        updates += 1;
        applicable.add(id);
      } else {
        conflicts += 1;
      }
    }
    final Map<String, Map<String, Object?>> incomingPeople =
        <String, Map<String, Object?>>{
          for (final Map<String, Object?> value in parsed.people)
            value['id']! as String: value,
        };
    final Map<String, Map<String, Object?>> incomingItems =
        <String, Map<String, Object?>>{
          for (final Map<String, Object?> value in parsed.items)
            value['id']! as String: value,
        };
    final Set<String> blockedBySharedParents = <String>{};
    for (final Map<String, Object?> incoming in parsed.exchanges.where(
      (Map<String, Object?> value) => applicable.contains(value['id']),
    )) {
      final String id = incoming['id']! as String;
      final String personId = incoming['personId']! as String;
      final String itemId = incoming['itemId']! as String;
      final PersonRow? localPerson = existingPeople[personId];
      final ItemRow? localItem = existingItems[itemId];
      final bool personDiffers =
          localPerson != null &&
          !_sameMap(_personMap(localPerson), incomingPeople[personId]!);
      final bool itemDiffers =
          localItem != null &&
          !_sameMap(_itemMap(localItem), incomingItems[itemId]!);
      final bool sharedPerson =
          personDiffers &&
          existingRows.any(
            (ExchangeRow row) =>
                row.id != id &&
                !applicable.contains(row.id) &&
                row.personId == personId,
          );
      final bool sharedItem =
          itemDiffers &&
          existingRows.any(
            (ExchangeRow row) =>
                row.id != id &&
                !applicable.contains(row.id) &&
                row.itemId == itemId,
          );
      if (sharedPerson || sharedItem) blockedBySharedParents.add(id);
    }
    for (final String id in blockedBySharedParents) {
      applicable.remove(id);
      if (additions.remove(id)) {
        adds -= 1;
      } else {
        updates -= 1;
      }
      conflicts += 1;
    }
    final Map<String, int?> expectedLocalVersions = <String, int?>{
      for (final String id in applicable)
        id: existing[id]?.updatedAt.millisecondsSinceEpoch,
    };
    return RestorePreview._(
      parsed,
      Set<String>.unmodifiable(applicable),
      Map<String, int?>.unmodifiable(expectedLocalVersions),
      adds: adds,
      updates: updates,
      conflicts: conflicts,
      missingAttachments: parsed.attachments
          .where((Map<String, Object?> value) => value['included'] == false)
          .length,
    );
  }

  /// Removes app-private attachments, restore snapshots, and staging data.
  ///
  /// Exports saved through the system picker are outside this root and are
  /// intentionally not touched.
  Future<void> deletePrivateBackupArtifacts() async {
    return withPrivateStorage(rootDirectory, (
      Directory root,
      PrivateStorageBoundary revalidate,
    ) async {
      for (final String name in <String>[
        'attachments',
        'backups',
        '.restore-staging',
        '.deletion-staging',
      ]) {
        await beforeFileBoundary?.call();
        await revalidate();
        final String path = '${root.path}/$name';
        final FileSystemEntityType type = await FileSystemEntity.type(
          path,
          followLinks: false,
        );
        switch (type) {
          case FileSystemEntityType.directory:
            await Directory(path).delete(recursive: true);
          case FileSystemEntityType.file:
          case FileSystemEntityType.pipe:
          case FileSystemEntityType.unixDomainSock:
            await File(path).delete();
          case FileSystemEntityType.link:
            await Link(path).delete();
          case FileSystemEntityType.notFound:
            break;
        }
      }
    });
  }

  Future<RestoreResult> applyRestore(RestorePreview preview) =>
      withPrivateStorage(
        rootDirectory,
        (Directory root, PrivateStorageBoundary revalidate) =>
            _applyRestore(root, revalidate, preview),
      );

  Future<RestoreResult> _applyRestore(
    Directory root,
    PrivateStorageBoundary revalidate,
    RestorePreview preview,
  ) async {
    await beforeFileBoundary?.call();
    await revalidate();

    final Directory snapshots = await _containedDirectory(root, 'backups');
    await snapshots.create(recursive: true);
    final BackupArtifact snapshot = await _createBackup(
      root,
      revalidate,
      includeAttachments: true,
    );

    final File snapshotFile = File(
      '${snapshots.path}/pre-restore-${_fileTimestamp(clock.now())}.zip',
    );
    await snapshotFile.writeAsBytes(snapshot.bytes, flush: true);

    final Set<String> ids = preview._applicableExchangeIds;
    final _ParsedBackup parsed = preview._parsed;
    final List<String> oldAttachmentPaths =
        (await (database.select(
              database.attachments,
            )..where((Attachments table) => table.exchangeId.isIn(ids))).get())
            .map((AttachmentRow row) => row.relativePath)
            .toList(growable: false);
    final _RestoreFilePlan filePlan = await _RestoreFilePlan.stage(
      root: root,
      parsed: parsed,
      exchangeIds: ids,
      oldAttachmentPaths: oldAttachmentPaths,
      nonce: clock.now().microsecondsSinceEpoch,
    );
    try {
      await database.transaction(() async {
        for (final String id in ids) {
          final ExchangeRow? current = await (database.select(
            database.exchanges,
          )..where((Exchanges table) => table.id.equals(id))).getSingleOrNull();
          if (current?.updatedAt.millisecondsSinceEpoch !=
              preview._expectedLocalVersions[id]) {
            throw const BackupException(
              'Local data changed after the restore preview. Preview again.',
            );
          }
        }
        for (final String id in ids) {
          await database.customStatement(
            'DELETE FROM reminders WHERE exchange_id = ?',
            <Object?>[id],
          );
          await database.customStatement(
            'DELETE FROM attachments WHERE exchange_id = ?',
            <Object?>[id],
          );
          await database.customStatement(
            'DELETE FROM exchange_events WHERE exchange_id = ?',
            <Object?>[id],
          );
          await database.customStatement(
            'DELETE FROM exchanges WHERE id = ?',
            <Object?>[id],
          );
        }

        final Set<String> personIds = parsed.exchanges
            .where((Map<String, Object?> row) => ids.contains(row['id']))
            .map((Map<String, Object?> row) => row['personId']! as String)
            .toSet();
        final Set<String> itemIds = parsed.exchanges
            .where((Map<String, Object?> row) => ids.contains(row['id']))
            .map((Map<String, Object?> row) => row['itemId']! as String)
            .toSet();
        for (final Map<String, Object?> row in parsed.people.where(
          (Map<String, Object?> row) => personIds.contains(row['id']),
        )) {
          await database.customStatement(
            'INSERT INTO people (id, display_name, private_note, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
            'display_name=excluded.display_name, private_note=excluded.private_note, '
            'created_at=excluded.created_at, updated_at=excluded.updated_at',
            <Object?>[
              row['id'],
              row['displayName'],
              row['privateNote'],
              _dbTime(_date(row, 'createdAt')),
              _dbTime(_date(row, 'updatedAt')),
            ],
          );
        }
        for (final Map<String, Object?> row in parsed.items.where(
          (Map<String, Object?> row) => itemIds.contains(row['id']),
        )) {
          await database.customStatement(
            'INSERT INTO items (id, name, description, category, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
            'name=excluded.name, description=excluded.description, category=excluded.category, '
            'created_at=excluded.created_at, updated_at=excluded.updated_at',
            <Object?>[
              row['id'],
              row['name'],
              row['description'],
              row['category'],
              _dbTime(_date(row, 'createdAt')),
              _dbTime(_date(row, 'updatedAt')),
            ],
          );
        }
        for (final Map<String, Object?> row in parsed.exchanges.where(
          (Map<String, Object?> row) => ids.contains(row['id']),
        )) {
          await database.customStatement(
            'INSERT INTO exchanges VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              row['id'],
              row['itemId'],
              row['personId'],
              row['direction'],
              _dbTime(_date(row, 'handedOffAt')),
              _dbNullableTime(_nullableDate(row, 'dueAt')),
              row['status'],
              _dbNullableTime(_nullableDate(row, 'returnedAt')),
              _dbTime(_date(row, 'createdAt')),
              _dbTime(_date(row, 'updatedAt')),
            ],
          );
        }
        for (final Map<String, Object?> row in parsed.events.where(
          (Map<String, Object?> row) => ids.contains(row['exchangeId']),
        )) {
          await database.customStatement(
            'INSERT INTO exchange_events VALUES (?, ?, ?, ?, ?)',
            <Object?>[
              row['id'],
              row['exchangeId'],
              row['type'],
              _dbTime(_date(row, 'occurredAt')),
              row['metadata'],
            ],
          );
        }
        for (final Map<String, Object?> row in parsed.attachments.where(
          (Map<String, Object?> row) => ids.contains(row['exchangeId']),
        )) {
          await database.customStatement(
            'INSERT INTO attachments VALUES (?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              row['id'],
              row['exchangeId'],
              row['itemId'],
              row['relativePath'],
              row['mediaType'],
              row['byteSize'],
              row['sha256'],
            ],
          );
        }
        for (final Map<String, Object?> row in parsed.reminders.where(
          (Map<String, Object?> row) => ids.contains(row['exchangeId']),
        )) {
          await database.customStatement(
            'INSERT INTO reminders VALUES (?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              row['exchangeId'],
              _dbTime(_date(row, 'requestedAt')),
              _dbTime(_date(row, 'scheduledAt')),
              row['platformSchedulingId'],
              row['title'],
              row['body'],
              row['deliveryState'],
            ],
          );
        }

        await beforeRestoreCommit?.call();
        await beforeFileBoundary?.call();
        await revalidate();
        await filePlan.apply();
      });
    } on Object {
      await filePlan.rollback();
      rethrow;
    } finally {
      await filePlan.cleanup();
    }
    return RestoreResult(
      added: preview.adds,
      updated: preview.updates,
      conflictsKept: preview.conflicts,
      preRestoreSnapshotPath: snapshotFile.path,
    );
  }
}

final class _RestoreFilePlan {
  _RestoreFilePlan(this.stagingDirectory, this.entries);

  final Directory stagingDirectory;
  final List<_RestoreFileEntry> entries;

  static Future<_RestoreFilePlan> stage({
    required Directory root,
    required _ParsedBackup parsed,
    required Set<String> exchangeIds,
    required List<String> oldAttachmentPaths,
    required int nonce,
  }) async {
    final Directory staging = await _containedDirectory(
      root,
      '.restore-staging/$nonce',
    );
    await staging.create(recursive: true);
    final List<_RestoreFileEntry> entries = <_RestoreFileEntry>[];
    try {
      final Set<String> incomingIncludedPaths = parsed.attachments
          .where(
            (Map<String, Object?> row) =>
                exchangeIds.contains(row['exchangeId']) &&
                row['included'] == true,
          )
          .map((Map<String, Object?> row) => row['relativePath']! as String)
          .toSet();
      for (final String relativePath in oldAttachmentPaths.toSet().difference(
        incomingIncludedPaths,
      )) {
        final File destination = await _containedFile(root, relativePath);
        File? previous;
        if (await destination.exists()) {
          previous = File('${staging.path}/removed-${entries.length}.previous');
          await destination.copy(previous.path);
        }
        entries.add(
          _RestoreFileEntry(
            staged: null,
            destination: destination,
            previous: previous,
          ),
        );
      }
      for (final Map<String, Object?> attachment in parsed.attachments.where(
        (Map<String, Object?> row) =>
            exchangeIds.contains(row['exchangeId']) && row['included'] == true,
      )) {
        final String id = attachment['id']! as String;
        final File staged = File('${staging.path}/$id.new');
        await staged.writeAsBytes(parsed.attachmentBytes[id]!, flush: true);
        final File destination = await _containedFile(
          root,
          attachment['relativePath'] as String,
        );
        File? previous;
        if (await destination.exists()) {
          previous = File('${staging.path}/$id.previous');
          await destination.copy(previous.path);
        }
        entries.add(
          _RestoreFileEntry(
            staged: staged,
            destination: destination,
            previous: previous,
          ),
        );
      }
      return _RestoreFilePlan(staging, entries);
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> apply() async {
    for (final _RestoreFileEntry entry in entries) {
      entry.started = true;
      if (entry.staged == null) {
        if (await entry.destination.exists()) await entry.destination.delete();
        continue;
      }
      await entry.destination.parent.create(recursive: true);
      await entry.destination.writeAsBytes(
        await entry.staged!.readAsBytes(),
        flush: true,
      );
    }
  }

  Future<void> rollback() async {
    for (final _RestoreFileEntry entry in entries.reversed) {
      if (!entry.started) continue;
      if (entry.previous case final File previous) {
        await entry.destination.parent.create(recursive: true);
        await previous.copy(entry.destination.path);
      } else if (await entry.destination.exists()) {
        await entry.destination.delete();
      }
    }
  }

  Future<void> cleanup() async {
    if (await stagingDirectory.exists()) {
      await stagingDirectory.delete(recursive: true);
    }
  }
}

final class _RestoreFileEntry {
  _RestoreFileEntry({
    required this.staged,
    required this.destination,
    required this.previous,
  });

  final File? staged;
  final File destination;
  final File? previous;
  bool started = false;
}

Future<File> _containedFile(Directory root, String relativePath) async =>
    File(await _containedPath(root, relativePath));

Future<Directory> _containedDirectory(
  Directory root,
  String relativePath,
) async => Directory(await _containedPath(root, relativePath));

Future<String> _containedPath(Directory root, String relativePath) async {
  final String safe = validateRelativePath(relativePath);
  final String rootPath = root.absolute.path;
  String current = rootPath;
  for (final String component in safe.split('/')) {
    current = '$current${Platform.pathSeparator}$component';
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw BackupException(
        'Path $relativePath contains a symbolic-link component.',
      );
    }
  }
  final String prefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  if (!current.startsWith(prefix)) {
    throw BackupException('Path $relativePath escapes private storage.');
  }
  return current;
}

final class _ParsedBackup {
  const _ParsedBackup({
    required this.people,
    required this.items,
    required this.exchanges,
    required this.events,
    required this.reminders,
    required this.attachments,
    required this.attachmentBytes,
  });
  final List<Map<String, Object?>> people;
  final List<Map<String, Object?>> items;
  final List<Map<String, Object?>> exchanges;
  final List<Map<String, Object?>> events;
  final List<Map<String, Object?>> reminders;
  final List<Map<String, Object?>> attachments;
  final Map<String, Uint8List> attachmentBytes;
}

_ParsedBackup _parse(Uint8List bytes) {
  if (bytes.length > _maxCompressedBackupBytes) {
    throw const BackupException('The selected backup is too large.');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } on Object {
    throw const BackupException('The selected file is not a valid ZIP backup.');
  }
  if (archive.files.length > _maxArchiveEntries) {
    throw const BackupException('The backup contains too many files.');
  }
  int expandedBytes = 0;
  final Map<String, ArchiveFile> files = <String, ArchiveFile>{};
  for (final ArchiveFile file in archive.files) {
    if (file.size < 0 || file.size > _maxEntryBytes) {
      throw const BackupException('A backup entry exceeds the size limit.');
    }
    expandedBytes += file.size;
    if (expandedBytes > _maxExpandedBackupBytes) {
      throw const BackupException('The expanded backup is too large.');
    }
    final String path;
    try {
      path = validateRelativePath(file.name);
    } on InvalidValue {
      throw const BackupException('The backup contains an unsafe path.');
    }
    if (files.containsKey(path)) {
      throw BackupException('The backup contains duplicate path $path.');
    }
    files[path] = file;
  }
  final ArchiveFile? jsonFile = files[backupSchemaFile];
  if (jsonFile == null || !jsonFile.isFile) {
    throw const BackupException('The backup is missing backup.json.');
  }
  if (jsonFile.size > _maxManifestBytes) {
    throw const BackupException('backup.json exceeds the size limit.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(jsonFile.content as List<int>));
  } on Object {
    throw const BackupException('backup.json is not valid UTF-8 JSON.');
  }
  if (decoded is! Map<String, Object?>) {
    throw const BackupException('backup.json must contain a JSON object.');
  }
  if (decoded['format'] != 'lend-loop-backup') {
    throw const BackupException('This is not a Lend Loop backup.');
  }
  final Object? versionValue = decoded['schemaVersion'];
  if (versionValue is! int || versionValue < 0) {
    throw const BackupException('The backup schema version is invalid.');
  }
  if (versionValue > currentBackupSchemaVersion) {
    throw BackupException(
      'Backup schema $versionValue is newer than this app supports.',
    );
  }
  _parseTimestamp(decoded['exportedAt'], 'exportedAt');
  if (versionValue == 0) {
    decoded.putIfAbsent(
      'requiredFields',
      () => <Object?>['people', 'items', 'exchanges', 'events'],
    );
    decoded.putIfAbsent('reminders', () => <Object?>[]);
    decoded.putIfAbsent('attachments', () => <Object?>[]);
  }
  final List<Object?> required = _list(decoded, 'requiredFields');
  for (final Object? name in required) {
    if (name is! String || !_requiredCollections.contains(name)) {
      throw BackupException('The backup requires unknown field $name.');
    }
  }
  for (final String field in required.cast<String>()) {
    if (!decoded.containsKey(field)) {
      throw BackupException('The backup is missing required field $field.');
    }
  }

  final List<Map<String, Object?>> people = _maps(decoded, 'people');
  final List<Map<String, Object?>> items = _maps(decoded, 'items');
  final List<Map<String, Object?>> exchanges = _maps(decoded, 'exchanges');
  final List<Map<String, Object?>> events = _maps(decoded, 'events');
  final List<Map<String, Object?>> reminders = _maps(decoded, 'reminders');
  final List<Map<String, Object?>> attachments = _maps(decoded, 'attachments');
  _uniqueIds(people, 'people');
  _uniqueIds(items, 'items');
  _uniqueIds(exchanges, 'exchanges');
  _uniqueIds(events, 'events');
  _uniqueIds(attachments, 'attachments');
  final Set<String> reminderIds = <String>{};

  for (final Map<String, Object?> row in people) {
    _id(row, 'id');
    _nonEmpty(row, 'displayName');
    _nullableString(row, 'privateNote');
    _date(row, 'createdAt');
    _date(row, 'updatedAt');
  }
  for (final Map<String, Object?> row in items) {
    _id(row, 'id');
    _nonEmpty(row, 'name');
    _nullableString(row, 'description');
    _nullableString(row, 'category');
    _date(row, 'createdAt');
    _date(row, 'updatedAt');
  }
  final Set<String> peopleIds = people
      .map((Map<String, Object?> e) => e['id']! as String)
      .toSet();
  final Set<String> itemIds = items
      .map((Map<String, Object?> e) => e['id']! as String)
      .toSet();
  final Set<String> exchangeIds = exchanges
      .map((Map<String, Object?> e) => e['id']! as String)
      .toSet();
  final Map<String, String> exchangeItemIds = <String, String>{};
  for (final Map<String, Object?> row in exchanges) {
    final String exchangeId = _id(row, 'id');
    final String itemId = _id(row, 'itemId');
    final String personId = _id(row, 'personId');
    if (!itemIds.contains(itemId) || !peopleIds.contains(personId)) {
      throw const BackupException('An exchange has missing linked data.');
    }
    _enumValue(row, 'direction', <String>{'lent', 'borrowed'});
    final DateTime handoff = _date(row, 'handedOffAt');
    final DateTime? due = _nullableDate(row, 'dueAt');
    final String status = _enumValue(row, 'status', <String>{
      'open',
      'returned',
    });
    final DateTime? returned = _nullableDate(row, 'returnedAt');
    _date(row, 'createdAt');
    _date(row, 'updatedAt');
    if (due != null && due.isBefore(handoff)) {
      throw const BackupException('An exchange due time precedes its handoff.');
    }
    if ((status == 'open') != (returned == null)) {
      throw const BackupException(
        'An exchange status and return time disagree.',
      );
    }
    exchangeItemIds[exchangeId] = itemId;
  }
  for (final Map<String, Object?> row in events) {
    _id(row, 'id');
    if (!exchangeIds.contains(_id(row, 'exchangeId'))) {
      throw const BackupException('An event references a missing exchange.');
    }
    _enumValue(row, 'type', <String>{
      'created',
      'edited',
      'reminded',
      'returned',
      'reopened',
    });
    _date(row, 'occurredAt');
    _nullableString(row, 'metadata');
  }
  for (final Map<String, Object?> row in reminders) {
    final String exchangeId = _id(row, 'exchangeId');
    if (!exchangeIds.contains(exchangeId) || !reminderIds.add(exchangeId)) {
      throw const BackupException('Reminder IDs are duplicate or invalid.');
    }
    _date(row, 'requestedAt');
    _date(row, 'scheduledAt');
    if (row['platformSchedulingId'] is! int) {
      throw const BackupException('A reminder scheduling ID is invalid.');
    }
    _nonEmpty(row, 'title');
    _nonEmpty(row, 'body');
    _enumValue(row, 'deliveryState', <String>{'pending', 'scheduled'});
  }

  final Map<String, Uint8List> attachmentBytes = <String, Uint8List>{};
  final Set<String> declaredArchivePaths = <String>{backupSchemaFile};
  final Set<String> attachmentRelativePaths = <String>{};
  for (final Map<String, Object?> row in attachments) {
    final String id = _id(row, 'id');
    final String exchangeId = _id(row, 'exchangeId');
    if (!exchangeIds.contains(exchangeId)) {
      throw const BackupException(
        'An attachment references a missing exchange.',
      );
    }
    final Object? itemId = row['itemId'];
    if (itemId != null &&
        (itemId is! String ||
            !itemIds.contains(itemId) ||
            itemId != exchangeItemIds[exchangeId])) {
      throw const BackupException(
        'An attachment item does not match its exchange.',
      );
    }
    final String relativePath;
    try {
      relativePath = validateRelativePath(_nonEmpty(row, 'relativePath'));
    } on InvalidValue {
      throw const BackupException('An attachment has an unsafe relative path.');
    }
    if (!attachmentRelativePaths.add(relativePath)) {
      throw BackupException(
        'Attachments contain duplicate relative path $relativePath.',
      );
    }
    _nonEmpty(row, 'mediaType');
    final Object? size = row['byteSize'];
    final String digest = _nonEmpty(row, 'sha256');
    if (size is! int ||
        size < 0 ||
        size > _maxEntryBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const BackupException('An attachment size or SHA-256 is invalid.');
    }
    if (row['included'] is! bool) {
      throw const BackupException('An attachment included flag is invalid.');
    }
    if (row['included'] == false) {
      if (row['archivePath'] != null) {
        throw const BackupException(
          'An omitted attachment has an archive path.',
        );
      }
      continue;
    }
    final String archivePath;
    try {
      archivePath = validateRelativePath(_nonEmpty(row, 'archivePath'));
    } on InvalidValue {
      throw const BackupException('An attachment archive path is unsafe.');
    }
    final ArchiveFile? file = files[archivePath];
    if (file == null ||
        !file.isFile ||
        !declaredArchivePaths.add(archivePath)) {
      throw const BackupException(
        'An included attachment is missing or duplicated.',
      );
    }
    final Uint8List content = Uint8List.fromList(file.content as List<int>);
    if (content.length != size ||
        sha256.convert(content).toString() != digest) {
      throw BackupException('Attachment $id failed its size or SHA-256 check.');
    }
    attachmentBytes[id] = content;
  }
  if (files.keys.any((String path) => !declaredArchivePaths.contains(path))) {
    throw const BackupException('The backup contains undeclared files.');
  }
  return _ParsedBackup(
    people: people,
    items: items,
    exchanges: exchanges,
    events: events,
    reminders: reminders,
    attachments: attachments,
    attachmentBytes: attachmentBytes,
  );
}

Map<String, Object?> _personMap(PersonRow row) => <String, Object?>{
  'id': row.id,
  'displayName': row.displayName,
  'privateNote': row.privateNote,
  'createdAt': _timestamp(row.createdAt),
  'updatedAt': _timestamp(row.updatedAt),
};

Map<String, Object?> _itemMap(ItemRow row) => <String, Object?>{
  'id': row.id,
  'name': row.name,
  'description': row.description,
  'category': row.category,
  'createdAt': _timestamp(row.createdAt),
  'updatedAt': _timestamp(row.updatedAt),
};

Map<String, Object?> _exchangeMap(ExchangeRow row) => <String, Object?>{
  'id': row.id,
  'itemId': row.itemId,
  'personId': row.personId,
  'direction': row.direction,
  'handedOffAt': _timestamp(row.handedOffAt),
  'dueAt': row.dueAt == null ? null : _timestamp(row.dueAt!),
  'status': row.status,
  'returnedAt': row.returnedAt == null ? null : _timestamp(row.returnedAt!),
  'createdAt': _timestamp(row.createdAt),
  'updatedAt': _timestamp(row.updatedAt),
};

List<Object?> _list(Map<String, Object?> object, String field) {
  final Object? value = object[field];
  if (value is! List<Object?>) {
    throw BackupException('Field $field must be a list.');
  }
  return value;
}

List<Map<String, Object?>> _maps(Map<String, Object?> object, String field) =>
    _list(object, field)
        .map((Object? value) {
          if (value is! Map<String, Object?>) {
            throw BackupException('Entries in $field must be JSON objects.');
          }
          return value;
        })
        .toList(growable: false);

void _uniqueIds(List<Map<String, Object?>> rows, String collection) {
  final Set<String> ids = <String>{};
  for (final Map<String, Object?> row in rows) {
    final String id = _id(row, 'id');
    if (!ids.add(id)) {
      throw BackupException('$collection contains duplicate ID $id.');
    }
  }
}

String _id(Map<String, Object?> object, String field) {
  final String value = _nonEmpty(object, field);
  try {
    return TypedBackupId(value).value;
  } on InvalidValue {
    throw BackupException('Field $field contains an invalid ID.');
  }
}

final class TypedBackupId extends TypedId {
  TypedBackupId(super.value);
}

String _nonEmpty(Map<String, Object?> object, String field) {
  final Object? value = object[field];
  if (value is! String || value.trim().isEmpty) {
    throw BackupException('Field $field must be a non-empty string.');
  }
  return value;
}

void _nullableString(Map<String, Object?> object, String field) {
  if (!object.containsKey(field) ||
      (object[field] != null && object[field] is! String)) {
    throw BackupException('Field $field must be a string or null.');
  }
}

String _enumValue(
  Map<String, Object?> object,
  String field,
  Set<String> allowed,
) {
  final String value = _nonEmpty(object, field);
  if (!allowed.contains(value)) {
    throw BackupException('Field $field has unsupported value $value.');
  }
  return value;
}

DateTime _date(Map<String, Object?> object, String field) =>
    _parseTimestamp(object[field], field);

DateTime? _nullableDate(Map<String, Object?> object, String field) {
  if (!object.containsKey(field)) {
    throw BackupException('Field $field is required.');
  }
  final Object? value = object[field];
  return value == null ? null : _parseTimestamp(value, field);
}

DateTime _parseTimestamp(Object? value, String field) {
  if (value is! String || !value.endsWith('Z')) {
    throw BackupException('Field $field must be an ISO-8601 UTC timestamp.');
  }
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) {
    throw BackupException('Field $field must be an ISO-8601 UTC timestamp.');
  }
  return parsed;
}

String _timestamp(DateTime value) => value.toUtc().toIso8601String();

int _dbTime(DateTime value) => value.toUtc().millisecondsSinceEpoch ~/ 1000;

int? _dbNullableTime(DateTime? value) => value == null ? null : _dbTime(value);

String _fileTimestamp(DateTime value) {
  final DateTime utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}T'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

String _csvCell(Object? value) {
  final String text = value?.toString() ?? '';
  if (!text.contains(RegExp('[,"\\r\\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}

bool _sameMap(Map<String, Object?> left, Map<String, Object?> right) =>
    jsonEncode(left) == jsonEncode(right);
