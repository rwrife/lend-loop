import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:lend_loop/data/backup_service.dart';

typedef BackupSavePicker = Future<Uri?> Function({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
});
typedef BackupOpenPicker = Future<Uint8List?> Function();

abstract interface class BackupFileAdapter {
  Future<bool> save(BackupArtifact artifact, {required String mimeType});
  Future<Uint8List?> pickBackup();
}

final class FilePickerBackupFileAdapter implements BackupFileAdapter {
  FilePickerBackupFileAdapter({BackupSavePicker? save, BackupOpenPicker? pick})
    : _save = save ?? _saveWithPicker,
      _pick = pick ?? _pickWithPicker;

  final BackupSavePicker _save;
  final BackupOpenPicker _pick;

  static Future<Uri?> _saveWithPicker({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) => FilePicker.saveFile(
    dialogTitle: 'Choose where to save your Lend Loop export',
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
  );

  static Future<Uint8List?> _pickWithPicker() async {
    final PlatformFile? selected = await FilePicker.pickFile(
      dialogTitle: 'Choose a Lend Loop ZIP backup',
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
    );
    return selected?.readAsBytes();
  }

  @override
  Future<bool> save(
    BackupArtifact artifact, {
    required String mimeType,
  }) async =>
      await _save(
        fileName: artifact.fileName,
        bytes: artifact.bytes,
        mimeType: mimeType,
      ) !=
      null;

  @override
  Future<Uint8List?> pickBackup() => _pick();
}
