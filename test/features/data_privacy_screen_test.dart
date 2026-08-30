import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/data/backup_service.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/features/data/data_privacy_screen.dart';
import 'package:lend_loop/platform/backup_file_adapter.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

final class _Ids implements IdGenerator {
  int value = 0;
  @override
  String nextId() => 'privacy-${value++}';
}

final class _Files implements BackupFileAdapter {
  final List<BackupArtifact> saved = <BackupArtifact>[];
  Uint8List? picked;
  @override
  Future<Uint8List?> pickBackup() async => picked;
  @override
  Future<bool> save(BackupArtifact artifact, {required String mimeType}) async {
    saved.add(artifact);
    return true;
  }
}

final class _Photos implements PhotoAdapter {
  final List<String> discarded = <String>[];
  bool failDiscard = false;
  bool failStage = false;
  @override
  Future<void> discard(String relativePath) async {
    discarded.add(relativePath);
    if (failDiscard) throw FileSystemException('injected cleanup failure');
  }

  @override
  Future<bool> deleteWithRollback(
    Iterable<String> relativePaths,
    Future<void> Function() deleteDatabase,
  ) async {
    if (failStage) {
      throw FileSystemException('injected staging failure');
    }
    await deleteDatabase();
    final List<String> paths = relativePaths.toList(growable: false);
    discarded.addAll(paths);
    return !failDiscard;
  }

  @override
  Future<PhotoPickResult> pickPhoto() async =>
      const PhotoPickResult.cancelled();
  @override
  Future<String?> resolve(String relativePath) async => null;
}

void main() {
  late LendLoopDatabase database;
  late Directory root;
  late ExchangeWorkflow workflow;
  late BackupService backups;
  late _Files files;
  late _Photos photos;
  final _Clock clock = _Clock(DateTime.utc(2026, 8, 28, 14));

  setUp(() async {
    database = LendLoopDatabase(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('lend-loop-privacy-ui-');
    workflow = ExchangeWorkflow(
      repository: DriftExchangeRepository(database),
      clock: clock,
      ids: _Ids(),
    );
    backups = BackupService(
      database: database,
      rootDirectory: () async => root,
      clock: clock,
    );
    files = _Files();
    photos = _Photos();
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  Future<void> seed() async {
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Drill',
        personName: 'Sam',
        handedOffAt: clock.now(),
      ),
      attachment: const AttachmentDraft(
        relativePath: 'attachments/drill.jpg',
        mediaType: 'image/jpeg',
        byteSize: 1,
        digest:
            '04bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7c67e2d2d0a1d7',
      ),
    );
  }

  testWidgets(
    'exports explicitly and deletes all data only after confirmation',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await seed();
      final Directory snapshots = Directory('${root.path}/backups');
      snapshots.createSync(recursive: true);
      File('${snapshots.path}/pre-restore.zip').writeAsBytesSync(<int>[1]);
      await tester.pumpWidget(
        MaterialApp(
          home: DataPrivacyScreen(
            backups: backups,
            files: files,
            workflow: workflow,
            photos: photos,
            deletePrivateBackupArtifacts: () async {
              if (snapshots.existsSync()) snapshots.deleteSync(recursive: true);
            },
          ),
        ),
      );

      expect(find.textContaining('not encrypted'), findsOneWidget);
      await tester.tap(find.byKey(const Key('exportCsvButton')));
      await tester.pumpAndSettle();
      expect(files.saved.single.fileName, endsWith('.csv'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('deleteAllDataButton')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('deleteAllDataButton')));
      await tester.pumpAndSettle();
      expect(find.text('Delete all local data?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirmDeleteAllButton')));
      await tester.pumpAndSettle();

      expect(await workflow.openExchanges(), isEmpty);
      expect(snapshots.existsSync(), isFalse);
      expect(photos.discarded, <String>['attachments/drill.jpg']);
      expect(
        find.text(
          'All local records, attachments, and private restore snapshots were deleted.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('staging failure leaves all database records intact', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seed();
    photos.failStage = true;
    await tester.pumpWidget(
      MaterialApp(
        home: DataPrivacyScreen(
          backups: backups,
          files: files,
          workflow: workflow,
          photos: photos,
          deletePrivateBackupArtifacts: () async {},
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('deleteAllDataButton')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('deleteAllDataButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmDeleteAllButton')));
    await tester.pumpAndSettle();

    expect(await workflow.openExchanges(), hasLength(1));
    expect(
      find.text(
        'The action could not be completed. Check local records and photos before retrying.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('keeps deletion committed when private-file cleanup fails', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seed();
    photos.failDiscard = true;
    await tester.pumpWidget(
      MaterialApp(
        home: DataPrivacyScreen(
          backups: backups,
          files: files,
          workflow: workflow,
          photos: photos,
          deletePrivateBackupArtifacts: () async {
            throw FileSystemException('injected root cleanup failure');
          },
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('deleteAllDataButton')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('deleteAllDataButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmDeleteAllButton')));
    await tester.pumpAndSettle();

    expect(await workflow.openExchanges(), isEmpty);
    expect(
      find.text(
        'All database records were deleted, but some private files or reminders could not be removed.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('previews restore counts and makes confirmation explicit', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seed();
    files.picked = (await tester.runAsync(
      () => backups.createBackup(includeAttachments: false),
    ))!.bytes;
    await workflow.deleteAllLocalData();
    await tester.pumpWidget(
      MaterialApp(
        home: DataPrivacyScreen(
          backups: backups,
          files: files,
          workflow: workflow,
          photos: photos,
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('restoreBackupButton')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('restoreBackupButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Preview restore'), findsOneWidget);
    expect(find.textContaining('1 new exchange'), findsOneWidget);
    expect(await workflow.openExchanges(), isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await workflow.openExchanges(), isEmpty);
  });

  testWidgets('successful restore reconciles reminders', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seed();
    files.picked = (await tester.runAsync(
      () => backups.createBackup(includeAttachments: false),
    ))!.bytes;
    await workflow.deleteAllLocalData();
    int reconciliations = 0;
    final Completer<void> reconciled = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: DataPrivacyScreen(
          backups: backups,
          files: files,
          workflow: workflow,
          photos: photos,
          reconcileReminders: () async {
            reconciliations += 1;
            reconciled.complete();
          },
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('restoreBackupButton')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('restoreBackupButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmRestoreButton')));
    for (int i = 0; i < 100 && !reconciled.isCompleted; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(reconciled.isCompleted, isTrue);
    await tester.pumpAndSettle();

    expect(reconciliations, 1);
    expect(find.textContaining('Restore complete: 1 added'), findsOneWidget);
  });

  testWidgets(
    'restore reports reminder cleanup failure without denying success',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await seed();
      files.picked = (await tester.runAsync(
        () => backups.createBackup(includeAttachments: false),
      ))!.bytes;
      await workflow.deleteAllLocalData();
      final Completer<void> reconciliationAttempted = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: DataPrivacyScreen(
            backups: backups,
            files: files,
            workflow: workflow,
            photos: photos,
            reconcileReminders: () async {
              reconciliationAttempted.complete();
              throw StateError('cleanup failed');
            },
          ),
        ),
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('restoreBackupButton')),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('restoreBackupButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmRestoreButton')));
      for (int i = 0; i < 100 && !reconciliationAttempted.isCompleted; i += 1) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(reconciliationAttempted.isCompleted, isTrue);
      await tester.pumpAndSettle();

      expect(await workflow.openExchanges(), hasLength(1));
      expect(
        find.textContaining('Reminder cleanup failed; retry reminder setup.'),
        findsOneWidget,
      );
    },
  );
}
