import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/data/backup_service.dart';
import 'package:lend_loop/platform/backup_file_adapter.dart';

void main() {
  test('saves only after an explicit picker action', () async {
    String? name;
    Uint8List? saved;
    final FilePickerBackupFileAdapter adapter = FilePickerBackupFileAdapter(
      save:
          ({
            required String fileName,
            required Uint8List bytes,
            required String mimeType,
          }) async {
            name = fileName;
            saved = bytes;
            return Uri.parse('content://saved/$fileName');
          },
    );

    final bool accepted = await adapter.save(
      BackupArtifact(
        fileName: 'backup.zip',
        bytes: Uint8List.fromList(<int>[1, 2]),
      ),
      mimeType: 'application/zip',
    );

    expect(accepted, isTrue);
    expect(name, 'backup.zip');
    expect(saved, <int>[1, 2]);
  });

  test('reads bytes selected through the explicit restore picker', () async {
    final FilePickerBackupFileAdapter adapter = FilePickerBackupFileAdapter(
      pick: () async => Uint8List.fromList(<int>[3, 4]),
    );

    expect(await adapter.pickBackup(), <int>[3, 4]);
  });

  test(
    'cancelled save and open pickers make no implicit file choice',
    () async {
      final FilePickerBackupFileAdapter adapter = FilePickerBackupFileAdapter(
        save: ({required fileName, required bytes, required mimeType}) async =>
            null,
        pick: () async => null,
      );

      expect(
        await adapter.save(
          BackupArtifact(fileName: 'private.zip', bytes: Uint8List(0)),
          mimeType: 'application/zip',
        ),
        isFalse,
      );
      expect(await adapter.pickBackup(), isNull);
    },
  );
}
