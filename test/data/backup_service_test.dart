import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/data/backup_service.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

final class _SequenceIds implements IdGenerator {
  int value = 0;
  @override
  String nextId() => 'backup-${value++}';
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late Directory sourceRoot;
  late Directory restoredRoot;
  late LendLoopDatabase sourceDatabase;
  late LendLoopDatabase restoredDatabase;
  final DateTime now = DateTime.utc(2026, 8, 28, 12, 30);

  setUp(() async {
    sourceRoot = await Directory.systemTemp.createTemp('lend-loop-source-');
    restoredRoot = await Directory.systemTemp.createTemp('lend-loop-restore-');
    sourceDatabase = LendLoopDatabase(NativeDatabase.memory());
    restoredDatabase = LendLoopDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await sourceDatabase.close();
    await restoredDatabase.close();
    await sourceRoot.delete(recursive: true);
    await restoredRoot.delete(recursive: true);
  });

  Future<Exchange> seed({bool withAttachment = true}) async {
    final DriftExchangeRepository repository = DriftExchangeRepository(
      sourceDatabase,
    );
    final PersonAlias person = PersonAlias(
      id: PersonId('person-1'),
      displayName: 'Zoë, "Z"',
      privateNote: 'neighbor',
      createdAt: now,
      updatedAt: now,
    );
    final Item item = Item(
      id: ItemId('item-1'),
      name: 'Drill',
      description: '18V\nwith case',
      category: 'Tools',
      createdAt: now,
      updatedAt: now,
    );
    final (
      Exchange exchange,
      ExchangeEvent event,
    ) = ExchangeTransitions(clock: _FixedClock(now), ids: _SequenceIds())
        .create(
          id: ExchangeId('exchange-1'),
          itemId: item.id,
          personId: person.id,
          direction: ExchangeDirection.lent,
          handedOffAt: now.subtract(const Duration(days: 1)),
          dueAt: now.add(const Duration(days: 7)),
        );
    Attachment? attachment;
    if (withAttachment) {
      final File photo = File('${sourceRoot.path}/attachments/photo.jpg');
      await photo.parent.create(recursive: true);
      await photo.writeAsBytes(<int>[1, 2, 3, 4]);
      attachment = Attachment(
        id: AttachmentId('attachment-1'),
        exchangeId: exchange.id,
        itemId: item.id,
        relativePath: 'attachments/photo.jpg',
        mediaType: 'image/jpeg',
        byteSize: 4,
        digest:
            '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
      );
    }
    await repository.create(
      person,
      item,
      exchange,
      event,
      attachment: attachment,
    );
    await repository.saveReminder(
      Reminder(
        exchangeId: exchange.id,
        requestedAt: now,
        scheduledAt: now.add(const Duration(days: 7)),
        platformSchedulingId: 41,
        title: 'Return Drill',
        body: 'Drill lent to Zoë',
        deliveryState: ReminderDeliveryState.pending,
      ),
    );
    return exchange;
  }

  test(
    'exports documented UTF-8 CSV and versioned ZIP with attachments',
    () async {
      await seed();
      final BackupService service = BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      );

      final BackupArtifact csv = await service.createCsvExport();
      expect(csv.fileName, 'lend-loop-history-20260828T123000Z.csv');
      final String csvText = utf8.decode(csv.bytes);
      expect(csvText, startsWith('exchange_id,direction,status,'));
      expect(csvText, contains('"Zoë, ""Z"""'));
      expect(csvText, contains('"18V\nwith case"'));

      final BackupArtifact zip = await service.createBackup(
        includeAttachments: true,
      );
      final Archive archive = ZipDecoder().decodeBytes(zip.bytes);
      expect(archive.findFile('backup.json'), isNotNull);
      expect(
        archive.findFile('attachments/attachment-1/photo.jpg')!.content,
        <int>[1, 2, 3, 4],
      );
      final Map<String, Object?> manifest = jsonDecode(
        utf8.decode(archive.findFile('backup.json')!.content as List<int>),
      ) as Map<String, Object?>;
      expect(manifest['format'], 'lend-loop-backup');
      expect(manifest['schemaVersion'], 1);
      expect(manifest['exportedAt'], '2026-08-28T12:30:00.000Z');
      expect(
        (manifest['exchanges']! as List<Object?>).single,
        containsPair('id', 'exchange-1'),
      );
      expect(
        (manifest['events']! as List<Object?>).single,
        containsPair('type', 'created'),
      );
      expect(
        (manifest['reminders']! as List<Object?>).single,
        containsPair('deliveryState', 'pending'),
      );
      expect(
        (manifest['attachments']! as List<Object?>).single,
        containsPair('included', true),
      );
    },
  );

  test(
    'backup and CSV exports keep one SQLite snapshot during a write',
    () async {
      await sourceDatabase.close();
      final File databaseFile = File('${sourceRoot.path}/snapshot.sqlite');
      final sqlite.Database setup = sqlite.sqlite3.open(databaseFile.path);
      setup.execute('PRAGMA journal_mode = WAL');
      setup.close();
      sourceDatabase = LendLoopDatabase(NativeDatabase(databaseFile));
      final LendLoopDatabase writer = LendLoopDatabase(
        NativeDatabase(databaseFile),
      );
      addTearDown(writer.close);
      await seed(withAttachment: false);

      bool csvWriteBlocked = false;
      final BackupArtifact csv = await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
        afterFirstSnapshotRead: () async {
          try {
            await writer.customStatement(
              'UPDATE people SET display_name = ? WHERE id = ?',
              <Object?>['Changed concurrently', 'person-1'],
            );
          } on sqlite.SqliteException {
            csvWriteBlocked = true;
          }
        },
      ).createCsvExport();
      expect(csvWriteBlocked, isTrue);
      expect(utf8.decode(csv.bytes), contains('Zoë'));
      expect(utf8.decode(csv.bytes), isNot(contains('Changed concurrently')));

      bool backupWriteBlocked = false;
      final BackupArtifact backup = await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
        afterFirstSnapshotRead: () async {
          try {
            await writer.customStatement(
              'UPDATE items SET name = ? WHERE id = ?',
              <Object?>['Changed concurrently', 'item-1'],
            );
          } on sqlite.SqliteException {
            backupWriteBlocked = true;
          }
        },
      ).createBackup(includeAttachments: false);
      expect(backupWriteBlocked, isTrue);
      final Archive archive = ZipDecoder().decodeBytes(backup.bytes);
      final Map<String, Object?> manifest = jsonDecode(
        utf8.decode(archive.findFile(backupSchemaFile)!.content as List<int>),
      ) as Map<String, Object?>;
      expect(
        ((manifest['items']! as List<Object?>).single!
            as Map<String, Object?>)['name'],
        'Drill',
      );
    },
  );

  test('previews and transactionally restores a complete backup', () async {
    final Exchange source = await seed();
    final BackupService exporter = BackupService(
      database: sourceDatabase,
      rootDirectory: () async => sourceRoot,
      clock: _FixedClock(now),
    );
    final Uint8List bytes = (await exporter.createBackup(
      includeAttachments: true,
    )).bytes;
    final BackupService importer = BackupService(
      database: restoredDatabase,
      rootDirectory: () async => restoredRoot,
      clock: _FixedClock(now.add(const Duration(minutes: 1))),
    );

    final RestorePreview preview = await importer.previewRestore(bytes);
    expect(preview.adds, 1);
    expect(preview.updates, 0);
    expect(preview.conflicts, 0);
    expect(preview.missingAttachments, 0);
    final RestoreResult result = await importer.applyRestore(preview);

    final DriftExchangeRepository restored = DriftExchangeRepository(
      restoredDatabase,
    );
    expect((await restored.get(source.id))!.direction, ExchangeDirection.lent);
    expect(
      (await restored.events(source.id)).single.type,
      ExchangeEventType.created,
    );
    expect(
      (await restored.getReminder(source.id))!.deliveryState,
      ReminderDeliveryState.pending,
    );
    expect(
      await File('${restoredRoot.path}/attachments/photo.jpg').readAsBytes(),
      <int>[1, 2, 3, 4],
    );
    expect(await File(result.preRestoreSnapshotPath).exists(), isTrue);
  });

  test(
    'reports omitted attachments without rejecting the text backup',
    () async {
      await seed();
      final Uint8List bytes = (await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      ).createBackup(includeAttachments: false)).bytes;

      final RestorePreview preview = await BackupService(
        database: restoredDatabase,
        rootDirectory: () async => restoredRoot,
        clock: _FixedClock(now),
      ).previewRestore(bytes);

      expect(preview.adds, 1);
      expect(preview.missingAttachments, 1);
    },
  );

  test(
    'update with an omitted attachment removes the old private photo',
    () async {
      await seed();
      final BackupService exporter = BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      );
      final Uint8List complete = (await exporter.createBackup(
        includeAttachments: true,
      )).bytes;
      final BackupService importer = BackupService(
        database: restoredDatabase,
        rootDirectory: () async => restoredRoot,
        clock: _FixedClock(now),
      );
      await importer.applyRestore(await importer.previewRestore(complete));
      final File restoredPhoto = File(
        '${restoredRoot.path}/attachments/photo.jpg',
      );
      expect(await restoredPhoto.exists(), isTrue);
      final Uint8List newerWithoutPhoto = _rewriteManifest(
        (await exporter.createBackup(includeAttachments: false)).bytes,
        (Map<String, Object?> manifest) {
          ((manifest['exchanges']! as List<Object?>).single!
                  as Map<String, Object?>)['updatedAt'] =
              '2026-08-29T12:30:00.000Z';
        },
      );

      await importer.applyRestore(
        await importer.previewRestore(newerWithoutPhoto),
      );

      expect(await restoredPhoto.exists(), isFalse);
    },
  );

  test('migrates a schema-zero record-only backup', () async {
    await seed(withAttachment: false);
    final BackupService exporter = BackupService(
      database: sourceDatabase,
      rootDirectory: () async => sourceRoot,
      clock: _FixedClock(now),
    );
    final Uint8List legacy = _rewriteManifest(
      (await exporter.createBackup(includeAttachments: false)).bytes,
      (Map<String, Object?> manifest) {
        manifest['schemaVersion'] = 0;
        manifest.remove('requiredFields');
        manifest.remove('reminders');
        manifest.remove('attachments');
      },
    );

    final RestorePreview preview = await BackupService(
      database: restoredDatabase,
      rootDirectory: () async => restoredRoot,
      clock: _FixedClock(now),
    ).previewRestore(legacy);

    expect(preview.adds, 1);
    expect(preview.missingAttachments, 0);
  });

  test(
    'rejects future schemas, unknown requirements, duplicates, and bad data',
    () async {
      await seed();
      final BackupService importer = BackupService(
        database: restoredDatabase,
        rootDirectory: () async => restoredRoot,
        clock: _FixedClock(now),
      );
      final Uint8List original = (await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      ).createBackup(includeAttachments: false)).bytes;

      final List<Uint8List> invalid = <Uint8List>[
        _rewriteManifest(original, (Map<String, Object?> value) {
          value['schemaVersion'] = currentBackupSchemaVersion + 1;
        }),
        _rewriteManifest(original, (Map<String, Object?> value) {
          (value['requiredFields']! as List<Object?>).add('cloudSecrets');
        }),
        _rewriteManifest(original, (Map<String, Object?> value) {
          final List<Object?> people = value['people']! as List<Object?>;
          people.add(Map<String, Object?>.from(people.first! as Map));
        }),
        _rewriteManifest(original, (Map<String, Object?> value) {
          final List<Object?> attachments =
              value['attachments']! as List<Object?>;
          final Map<String, Object?> duplicate = Map<String, Object?>.from(
            attachments.first! as Map,
          )..['id'] = 'attachment-duplicate';
          attachments.add(duplicate);
        }),
        _rewriteManifest(original, (Map<String, Object?> value) {
          ((value['exchanges']! as List<Object?>).first!
                  as Map<String, Object?>)['handedOffAt'] =
              'not-a-timestamp';
        }),
        _rewriteManifest(original, (Map<String, Object?> value) {
          ((value['attachments']! as List<Object?>).first!
                  as Map<String, Object?>)['relativePath'] =
              '../private.jpg';
        }),
      ];

      for (final Uint8List bytes in invalid) {
        await expectLater(
          importer.previewRestore(bytes),
          throwsA(isA<BackupException>()),
        );
      }
    },
  );

  test(
    'rejects included attachment bytes that fail SHA-256 validation',
    () async {
      await seed();
      final Uint8List original = (await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      ).createBackup(includeAttachments: true)).bytes;
      final Uint8List corrupted = _rewriteManifest(
        original,
        (Map<String, Object?> _) {},
        replacementFiles: <String, List<int>>{
          'attachments/attachment-1/photo.jpg': <int>[9, 9, 9, 9],
        },
      );

      await expectLater(
        BackupService(
          database: restoredDatabase,
          rootDirectory: () async => restoredRoot,
          clock: _FixedClock(now),
        ).previewRestore(corrupted),
        throwsA(isA<BackupException>()),
      );
    },
  );

  test(
    'failed restore keeps the prior database and leaves a local snapshot',
    () async {
      final Exchange source = await seed();
      final Uint8List original = (await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      ).createBackup(includeAttachments: false)).bytes;
      final BackupService initialImporter = BackupService(
        database: restoredDatabase,
        rootDirectory: () async => restoredRoot,
        clock: _FixedClock(now),
      );
      await initialImporter.applyRestore(
        await initialImporter.previewRestore(original),
      );
      final Uint8List newer = _rewriteManifest(original, (
        Map<String, Object?> manifest,
      ) {
        final Map<String, Object?> exchange =
            (manifest['exchanges']! as List<Object?>).single!
                as Map<String, Object?>;
        exchange['updatedAt'] = '2026-08-29T12:30:00.000Z';
        exchange['dueAt'] = '2026-08-30T12:30:00.000Z';
      });
      final BackupService failingImporter = BackupService(
        database: restoredDatabase,
        rootDirectory: () async => restoredRoot,
        clock: _FixedClock(now.add(const Duration(minutes: 2))),
        beforeRestoreCommit: () async =>
            throw StateError('injected restore failure'),
      );
      final RestorePreview preview = await failingImporter.previewRestore(
        newer,
      );
      expect(preview.updates, 1);

      await expectLater(
        failingImporter.applyRestore(preview),
        throwsStateError,
      );

      final Exchange unchanged = (await DriftExchangeRepository(
        restoredDatabase,
      ).get(source.id))!;
      expect(unchanged.updatedAt.isAtSameMomentAs(now), isTrue);
      expect(
        unchanged.dueAt!.isAtSameMomentAs(now.add(const Duration(days: 7))),
        isTrue,
      );
      expect(
        Directory('${restoredRoot.path}/backups').listSync().whereType<File>(),
        isNotEmpty,
      );
    },
  );

  test(
    'requires a fresh preview when local data changes before apply',
    () async {
      await seed(withAttachment: false);
      final Uint8List original = (await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      ).createBackup(includeAttachments: false)).bytes;
      final BackupService importer = BackupService(
        database: restoredDatabase,
        rootDirectory: () async => restoredRoot,
        clock: _FixedClock(now),
      );
      await importer.applyRestore(await importer.previewRestore(original));
      final Uint8List newer = _rewriteManifest(original, (
        Map<String, Object?> manifest,
      ) {
        ((manifest['exchanges']! as List<Object?>).single!
                as Map<String, Object?>)['updatedAt'] =
            '2026-08-29T12:30:00.000Z';
      });
      final RestorePreview preview = await importer.previewRestore(newer);
      await (restoredDatabase.update(
        restoredDatabase.exchanges,
      )..where((Exchanges table) => table.id.equals('exchange-1'))).write(
        ExchangesCompanion(
          updatedAt: Value<DateTime>(now.add(const Duration(hours: 2))),
        ),
      );

      await expectLater(
        importer.applyRestore(preview),
        throwsA(isA<BackupException>()),
      );
      expect(
        (await DriftExchangeRepository(restoredDatabase)
                .get(ExchangeId('exchange-1')))!
            .updatedAt
            .isAtSameMomentAs(now.add(const Duration(hours: 2))),
        isTrue,
      );
    },
  );

  test('keeps local parent labels used by a retained exchange', () async {
    await seed(withAttachment: false);
    final Uint8List original = (await BackupService(
      database: sourceDatabase,
      rootDirectory: () async => sourceRoot,
      clock: _FixedClock(now),
    ).createBackup(includeAttachments: false)).bytes;
    final BackupService importer = BackupService(
      database: restoredDatabase,
      rootDirectory: () async => restoredRoot,
      clock: _FixedClock(now),
    );
    await importer.applyRestore(await importer.previewRestore(original));
    await restoredDatabase.customStatement(
      'INSERT INTO exchanges VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        'local-only',
        'item-1',
        'person-1',
        'lent',
        now.millisecondsSinceEpoch,
        null,
        'open',
        null,
        now.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      ],
    );
    await restoredDatabase.customStatement(
      'UPDATE people SET display_name = ? WHERE id = ?',
      <Object?>['Local Morgan', 'person-1'],
    );
    final Uint8List newer = _rewriteManifest(original, (
      Map<String, Object?> manifest,
    ) {
      ((manifest['people']! as List<Object?>).single!
              as Map<String, Object?>)['displayName'] =
          'Backup Morgan';
      ((manifest['exchanges']! as List<Object?>).single!
              as Map<String, Object?>)['updatedAt'] =
          '2026-08-29T12:30:00.000Z';
    });

    final RestorePreview preview = await importer.previewRestore(newer);

    expect(preview.updates, 0);
    expect(preview.conflicts, 1);
    expect(
      (await DriftExchangeRepository(restoredDatabase)
              .getPerson(PersonId('person-1')))!
          .displayName,
      'Local Morgan',
    );
  });

  test('filesystem failure rolls back database restore changes', () async {
    await seed();
    final Uint8List bytes = (await BackupService(
      database: sourceDatabase,
      rootDirectory: () async => sourceRoot,
      clock: _FixedClock(now),
    ).createBackup(includeAttachments: true)).bytes;
    await File('${restoredRoot.path}/attachments')
        .writeAsString('not a folder');
    final BackupService importer = BackupService(
      database: restoredDatabase,
      rootDirectory: () async => restoredRoot,
      clock: _FixedClock(now),
    );

    await expectLater(
      importer.applyRestore(await importer.previewRestore(bytes)),
      throwsA(isA<FileSystemException>()),
    );

    expect(
      await DriftExchangeRepository(restoredDatabase)
          .find(const ExchangeQuery()),
      isEmpty,
    );
    expect(
      await File('${restoredRoot.path}/attachments').readAsString(),
      'not a folder',
    );
  });

  test(
    'delete-all cleanup removes orphan attachments and backup artifacts',
    () async {
      final Directory snapshots = Directory('${sourceRoot.path}/backups');
      final Directory staging = Directory(
        '${sourceRoot.path}/.restore-staging',
      );
      final File attachment = File('${sourceRoot.path}/attachments/keep.jpg');
      await snapshots.create(recursive: true);
      await staging.create(recursive: true);
      await attachment.parent.create(recursive: true);
      await File('${snapshots.path}/snapshot.zip').writeAsBytes(<int>[1]);
      await File('${staging.path}/staged').writeAsBytes(<int>[2]);
      await attachment.writeAsBytes(<int>[3]);

      await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      ).deletePrivateBackupArtifacts();

      expect(await snapshots.exists(), isFalse);
      expect(await staging.exists(), isFalse);
      expect(await attachment.exists(), isFalse);
    },
  );

  test(
    'rejects attachment paths containing a symbolic-link component',
    () async {
      await seed();
      final Directory outside = await Directory.systemTemp.createTemp(
        'lend-loop-outside-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await File('${outside.path}/photo.jpg').writeAsBytes(<int>[1, 2, 3, 4]);
      await Directory('${sourceRoot.path}/attachments').delete(recursive: true);
      await Link('${sourceRoot.path}/attachments').create(outside.path);

      await expectLater(
        BackupService(
          database: sourceDatabase,
          rootDirectory: () async => sourceRoot,
          clock: _FixedClock(now),
        ).createBackup(includeAttachments: true),
        throwsA(isA<BackupException>()),
      );
    },
  );

  test('canonicalizes a trusted system-style symlink ancestor', () async {
    final Directory parent = await Directory.systemTemp.createTemp(
      'lend-loop-root-ancestor-',
    );
    addTearDown(() => parent.delete(recursive: true));
    final Directory realRoot = Directory('${parent.path}/real/root');
    await realRoot.create(recursive: true);
    await Link('${parent.path}/alias').create('${parent.path}/real');
    final Directory suppliedRoot = Directory('${parent.path}/alias/root');

    final BackupArtifact backup = await BackupService(
      database: sourceDatabase,
      rootDirectory: () async => suppliedRoot,
      clock: _FixedClock(now),
    ).createBackup(includeAttachments: false);

    expect(
      ZipDecoder().decodeBytes(backup.bytes).findFile(backupSchemaFile),
      isNotNull,
    );
  });

  test('rejects a symbolic-link private-storage root', () async {
    final Directory parent = await Directory.systemTemp.createTemp(
      'lend-loop-root-link-',
    );
    addTearDown(() => parent.delete(recursive: true));
    final Link rootLink = await Link('${parent.path}/root')
        .create(sourceRoot.path);

    await expectLater(
      BackupService(
        database: sourceDatabase,
        rootDirectory: () async => Directory(rootLink.path),
        clock: _FixedClock(now),
      ).createBackup(includeAttachments: true),
      throwsA(isA<InvalidValue>()),
    );
  });

  test(
    'revalidates containment at the attachment operation boundary',
    () async {
      await seed();
      final Directory outside = await Directory.systemTemp.createTemp(
        'lend-loop-race-outside-',
      );
      addTearDown(() => outside.delete(recursive: true));
      bool raced = false;
      final BackupService service = BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
        beforeFileBoundary: () async {
          if (raced) return;
          raced = true;
          await Directory('${sourceRoot.path}/attachments')
              .delete(recursive: true);
          await Link('${sourceRoot.path}/attachments').create(outside.path);
        },
      );

      await expectLater(
        service.createBackup(includeAttachments: true),
        throwsA(isA<BackupException>()),
      );
      expect(await outside.list().isEmpty, isTrue);
    },
  );

  test(
    'rejects restore destinations containing a symbolic-link component',
    () async {
      await seed();
      final Uint8List bytes = (await BackupService(
        database: sourceDatabase,
        rootDirectory: () async => sourceRoot,
        clock: _FixedClock(now),
      ).createBackup(includeAttachments: true)).bytes;
      final Directory outside = await Directory.systemTemp.createTemp(
        'lend-loop-outside-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await Link('${restoredRoot.path}/attachments').create(outside.path);

      await expectLater(
        BackupService(
          database: restoredDatabase,
          rootDirectory: () async => restoredRoot,
          clock: _FixedClock(now),
        ).applyRestore(
          await BackupService(
            database: restoredDatabase,
            rootDirectory: () async => restoredRoot,
            clock: _FixedClock(now),
          ).previewRestore(bytes),
        ),
        throwsA(isA<BackupException>()),
      );
      expect(await outside.list().isEmpty, isTrue);
    },
  );

  test('rejects declared attachment sizes above the resource limit', () async {
    await seed();
    final Uint8List original = (await BackupService(
      database: sourceDatabase,
      rootDirectory: () async => sourceRoot,
      clock: _FixedClock(now),
    ).createBackup(includeAttachments: false)).bytes;
    final Uint8List oversized = _rewriteManifest(original, (
      Map<String, Object?> manifest,
    ) {
      ((manifest['attachments']! as List<Object?>).single!
              as Map<String, Object?>)['byteSize'] =
          100 * 1024 * 1024 + 1;
    });

    await expectLater(
      BackupService(
        database: restoredDatabase,
        rootDirectory: () async => restoredRoot,
        clock: _FixedClock(now),
      ).previewRestore(oversized),
      throwsA(isA<BackupException>()),
    );
  });
}

Uint8List _rewriteManifest(
  Uint8List source,
  void Function(Map<String, Object?> manifest) mutate, {
  Map<String, List<int>> replacementFiles = const <String, List<int>>{},
}) {
  final Archive decoded = ZipDecoder().decodeBytes(source);
  final Archive output = Archive();
  for (final ArchiveFile file in decoded.files) {
    if (file.name == backupSchemaFile) continue;
    final List<int> content =
        replacementFiles[file.name] ??
        List<int>.from(file.content as List<int>);
    output.addFile(ArchiveFile(file.name, content.length, content));
  }
  final ArchiveFile manifestFile = decoded.findFile(backupSchemaFile)!;
  final Map<String, Object?> manifest = jsonDecode(
    utf8.decode(manifestFile.content as List<int>),
  ) as Map<String, Object?>;
  mutate(manifest);
  final List<int> encodedManifest = utf8.encode(jsonEncode(manifest));
  output.addFile(
    ArchiveFile(backupSchemaFile, encodedManifest.length, encodedManifest),
  );
  return Uint8List.fromList(ZipEncoder().encode(output));
}
