import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lend_loop/platform/image_picker_photo_adapter.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lend-loop-photo-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('copies a selected photo into private portable storage', () async {
    final File source = File('${root.path}/source.jpg');
    await source.writeAsBytes(<int>[97, 98, 99]);
    final ImagePickerPhotoAdapter adapter = ImagePickerPhotoAdapter(
      pick: () async => XFile(source.path, mimeType: 'image/jpeg'),
      rootDirectory: () async => root,
    );

    final PhotoPickResult result = await adapter.pickPhoto();

    expect(result.status, PhotoPickStatus.selected);
    expect(result.relativePath, startsWith('attachments/'));
    expect(result.relativePath, endsWith('.jpg'));
    expect(result.mediaType, 'image/jpeg');
    expect(result.byteSize, 3);
    expect(
      result.digest,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    final String? absolute = await adapter.resolve(result.relativePath!);
    expect(absolute, isNotNull);
    expect(await File(absolute!).readAsBytes(), <int>[97, 98, 99]);

    await adapter.discard(result.relativePath!);
    expect(await adapter.resolve(result.relativePath!), isNull);
  });

  test(
    'maps cancellation and permission denial without creating a file',
    () async {
      final ImagePickerPhotoAdapter cancelled = ImagePickerPhotoAdapter(
        pick: () async => null,
        rootDirectory: () async => root,
      );
      final ImagePickerPhotoAdapter denied = ImagePickerPhotoAdapter(
        pick: () async => throw PlatformException(code: 'photo_access_denied'),
        rootDirectory: () async => root,
      );

      expect((await cancelled.pickPhoto()).status, PhotoPickStatus.cancelled);
      expect((await denied.pickPhoto()).status, PhotoPickStatus.denied);
      expect(await Directory('${root.path}/attachments').exists(), isFalse);
    },
  );

  test(
    'maps camera denial and revocation without retaining a staged copy',
    () async {
      for (final String code in <String>[
        'camera_access_denied',
        'camera_access_restricted',
        'photo_access_restricted',
      ]) {
        final ImagePickerPhotoAdapter adapter = ImagePickerPhotoAdapter(
          pick: () async => throw PlatformException(code: code),
          rootDirectory: () async => root,
        );
        expect((await adapter.pickPhoto()).status, PhotoPickStatus.denied);
      }
      expect(await Directory('${root.path}/attachments').exists(), isFalse);
    },
  );

  test(
    'stage failure leaves the tracked file and database unchanged',
    () async {
      final File photo = File('${root.path}/attachments/photo.jpg');
      await photo.parent.create(recursive: true);
      await photo.writeAsBytes(<int>[1]);
      bool databaseCalled = false;
      final ImagePickerPhotoAdapter adapter = ImagePickerPhotoAdapter(
        rootDirectory: () async => root,
        beforeStage: (_) async => throw FileSystemException('stage failed'),
      );

      await expectLater(
        adapter.deleteWithRollback(<String>['attachments/photo.jpg'], () async {
          databaseCalled = true;
        }),
        throwsA(isA<FileSystemException>()),
      );

      expect(databaseCalled, isFalse);
      expect(await photo.exists(), isTrue);
    },
  );

  test('database failure rolls a staged photo back', () async {
    final File photo = File('${root.path}/attachments/photo.jpg');
    await photo.parent.create(recursive: true);
    await photo.writeAsBytes(<int>[1]);
    final ImagePickerPhotoAdapter adapter = ImagePickerPhotoAdapter(
      rootDirectory: () async => root,
    );

    await expectLater(
      adapter.deleteWithRollback(<String>[
        'attachments/photo.jpg',
      ], () async => throw StateError('database failed')),
      throwsStateError,
    );

    expect(await photo.readAsBytes(), <int>[1]);
    expect(await Directory('${root.path}/.deletion-staging').exists(), isFalse);
  });

  test('unlink failure is reported and staged data is retried', () async {
    final File photo = File('${root.path}/attachments/photo.jpg');
    await photo.parent.create(recursive: true);
    await photo.writeAsBytes(<int>[1]);
    bool failFinalize = true;
    final ImagePickerPhotoAdapter adapter = ImagePickerPhotoAdapter(
      rootDirectory: () async => root,
      beforeFinalize: (_) async {
        if (failFinalize) throw FileSystemException('unlink failed');
      },
    );

    expect(
      await adapter.deleteWithRollback(<String>[
        'attachments/photo.jpg',
      ], () async {}),
      isFalse,
    );
    expect(await photo.exists(), isFalse);
    expect(await Directory('${root.path}/.deletion-staging').exists(), isTrue);

    failFinalize = false;
    expect(await adapter.deleteWithRollback(<String>[], () async {}), isTrue);
    expect(await Directory('${root.path}/.deletion-staging').exists(), isFalse);
  });
}
