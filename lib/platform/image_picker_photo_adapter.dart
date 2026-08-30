import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/photo_adapter.dart';
import 'package:lend_loop/platform/private_storage.dart';
import 'package:path_provider/path_provider.dart';

typedef PhotoPicker = Future<XFile?> Function();
typedef RootDirectoryProvider = Future<Directory> Function();

final class ImagePickerPhotoAdapter implements PhotoAdapter {
  ImagePickerPhotoAdapter({
    PhotoPicker? pick,
    RootDirectoryProvider? rootDirectory,
    Random? random,
    this.beforeStage,
    this.beforeFinalize,
    this.beforeBoundary,
  }) : _pick = pick ?? _defaultPick,
       _rootDirectory = rootDirectory ?? getApplicationSupportDirectory,
       _random = random ?? Random.secure();

  final PhotoPicker _pick;
  final RootDirectoryProvider _rootDirectory;
  final Random _random;
  final Future<void> Function(String path)? beforeStage;
  final Future<void> Function(String path)? beforeFinalize;
  final Future<void> Function()? beforeBoundary;

  static Future<XFile?> _defaultPick() =>
      ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92);

  @override
  Future<PhotoPickResult> pickPhoto() async {
    try {
      final XFile? selected = await _pick();
      if (selected == null) return const PhotoPickResult.cancelled();
      return await withPrivateStorage(_rootDirectory, (
        Directory root,
        PrivateStorageBoundary revalidate,
      ) async {
        final String extension = _safeExtension(selected.path);
        final String name =
            '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
            '${_random.nextInt(0x7fffffff).toRadixString(36)}$extension';
        final String relativePath = 'attachments/$name';
        final File destination = File(
          await containedPrivatePath(root, relativePath, revalidate),
        );
        await destination.parent.create(recursive: true);
        await containedPrivatePath(root, relativePath, revalidate);
        await selected.saveTo(destination.path);
        final int byteSize = await destination.length();
        final Digest digest = await sha256.bind(destination.openRead()).first;
        return PhotoPickResult.selected(
          relativePath: relativePath,
          mediaType: selected.mimeType ?? _mediaType(extension),
          byteSize: byteSize,
          digest: digest.toString(),
        );
      });
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
    return withPrivateStorage(_rootDirectory, (
      Directory root,
      PrivateStorageBoundary revalidate,
    ) async {
      final File file = File(
        await containedPrivatePath(root, portable, revalidate),
      );
      return await file.exists() ? file.path : null;
    });
  }

  @override
  Future<void> discard(String relativePath) async {
    final String portable = validateRelativePath(relativePath);
    await withPrivateStorage(_rootDirectory, (
      Directory root,
      PrivateStorageBoundary revalidate,
    ) async {
      final File file = File(
        await containedPrivatePath(root, portable, revalidate),
      );
      if (await file.exists()) await file.delete();
    });
  }

  @override
  Future<bool> deleteWithRollback(
    Iterable<String> relativePaths,
    Future<void> Function() deleteDatabase,
  ) => withPrivateStorage(_rootDirectory, (
    Directory root,
    PrivateStorageBoundary revalidate,
  ) async {
    final Directory deletionRoot = Directory('${root.path}/.deletion-staging');
    await revalidate();
    if (await deletionRoot.exists()) {
      await deletionRoot.delete(recursive: true);
    }
    final Directory staging = Directory(
      '${deletionRoot.path}/${DateTime.now().microsecondsSinceEpoch}',
    );
    final List<(File, File)> moved = <(File, File)>[];
    try {
      await revalidate();
      await staging.create(recursive: true);
      for (final String value in relativePaths) {
        final String relativePath = validateRelativePath(value);
        await beforeStage?.call(relativePath);
        await beforeBoundary?.call();
        await revalidate();
        final File source = File(
          await containedPrivatePath(root, relativePath, revalidate),
        );
        if (!await source.exists()) continue;
        final File staged = File('${staging.path}/${moved.length}.deleted');
        await source.rename(staged.path);
        moved.add((source, staged));
      }
      await deleteDatabase();
    } on Object {
      for (final (File source, File staged) in moved.reversed) {
        if (await staged.exists()) {
          await source.parent.create(recursive: true);
          await staged.rename(source.path);
        }
      }
      if (await staging.exists()) await staging.delete(recursive: true);
      if (await deletionRoot.exists() && await deletionRoot.list().isEmpty) {
        await deletionRoot.delete();
      }
      rethrow;
    }

    bool complete = true;
    for (final (File _, File staged) in moved) {
      try {
        await beforeFinalize?.call(staged.path);
        await revalidate();
        if (await staged.exists()) await staged.delete();
      } on Object {
        complete = false;
      }
    }
    if (complete) {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
        if (await deletionRoot.exists() && await deletionRoot.list().isEmpty) {
          await deletionRoot.delete();
        }
      } on Object {
        complete = false;
      }
    }
    return complete;
  });
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
