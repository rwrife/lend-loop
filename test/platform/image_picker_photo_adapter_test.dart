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
}
