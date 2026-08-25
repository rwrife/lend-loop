import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/photo_adapter.dart';
import 'package:path_provider/path_provider.dart';

typedef PhotoPicker = Future<XFile?> Function();
typedef RootDirectoryProvider = Future<Directory> Function();

final class ImagePickerPhotoAdapter implements PhotoAdapter {
  ImagePickerPhotoAdapter({
    PhotoPicker? pick,
    RootDirectoryProvider? rootDirectory,
    Random? random,
  }) : _pick = pick ?? _defaultPick,
       _rootDirectory = rootDirectory ?? getApplicationSupportDirectory,
       _random = random ?? Random.secure();

  final PhotoPicker _pick;
  final RootDirectoryProvider _rootDirectory;
  final Random _random;

  static Future<XFile?> _defaultPick() =>
      ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92);

  @override
  Future<PhotoPickResult> pickPhoto() async {
    try {
      final XFile? selected = await _pick();
      if (selected == null) return const PhotoPickResult.cancelled();
      final Directory root = await _rootDirectory();
      final Directory attachments = Directory('${root.path}/attachments');
      await attachments.create(recursive: true);
      final String extension = _safeExtension(selected.path);
      final String name =
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
          '${_random.nextInt(0x7fffffff).toRadixString(36)}$extension';
      final File destination = File('${attachments.path}/$name');
      await selected.saveTo(destination.path);
      final int byteSize = await destination.length();
      final Digest digest = await sha256.bind(destination.openRead()).first;
      return PhotoPickResult.selected(
        relativePath: 'attachments/$name',
        mediaType: selected.mimeType ?? _mediaType(extension),
        byteSize: byteSize,
        digest: digest.toString(),
      );
    } on PlatformException catch (error) {
      if (_isPermissionDenial(error.code)) {
        return const PhotoPickResult.denied();
      }
      rethrow;
    }
  }

  @override
  Future<String?> resolve(String relativePath) async {
    final String portable;
    try {
      portable = validateRelativePath(relativePath);
    } on InvalidValue {
      return null;
    }
    final Directory root = await _rootDirectory();
    final File file = File('${root.path}/$portable');
    return await file.exists() ? file.path : null;
  }

  @override
  Future<void> discard(String relativePath) async {
    final String? absolute = await resolve(relativePath);
    if (absolute == null) return;
    await File(absolute).delete();
  }
}

bool _isPermissionDenial(String code) => <String>{
  'camera_access_denied',
  'camera_access_restricted',
  'photo_access_denied',
  'photo_access_restricted',
}.contains(code);

String _safeExtension(String path) {
  final String filename = path.replaceAll('\\', '/').split('/').last;
  final int dot = filename.lastIndexOf('.');
  if (dot < 0) return '.jpg';
  final String extension = filename.substring(dot).toLowerCase();
  return <String>{
        '.jpg',
        '.jpeg',
        '.png',
        '.heic',
        '.heif',
        '.webp',
      }.contains(extension)
      ? extension
      : '.jpg';
}

String _mediaType(String extension) => switch (extension) {
  '.png' => 'image/png',
  '.heic' => 'image/heic',
  '.heif' => 'image/heif',
  '.webp' => 'image/webp',
  _ => 'image/jpeg',
};
