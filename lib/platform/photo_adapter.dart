enum PhotoPickStatus { selected, cancelled, denied }

final class PhotoPickResult {
  const PhotoPickResult.selected({
    required this.relativePath,
    required this.mediaType,
    required this.byteSize,
    required this.digest,
  }) : status = PhotoPickStatus.selected;

  const PhotoPickResult.cancelled()
    : status = PhotoPickStatus.cancelled,
      relativePath = null,
      mediaType = null,
      byteSize = null,
      digest = null;

  const PhotoPickResult.denied()
    : status = PhotoPickStatus.denied,
      relativePath = null,
      mediaType = null,
      byteSize = null,
      digest = null;

  final PhotoPickStatus status;
  final String? relativePath;
  final String? mediaType;
  final int? byteSize;
  final String? digest;
}

abstract interface class PhotoAdapter {
  Future<PhotoPickResult> pickPhoto();

  /// Resolves a portable path to an app-private absolute path, or null when
  /// the file has been removed or is otherwise unavailable.
  Future<String?> resolve(String relativePath);

  /// Removes a prepared photo that was not committed to a record.
  Future<void> discard(String relativePath);

  /// Stages [relativePaths], runs the database deletion, and restores the
  /// files if that deletion fails. Returns false when committed database work
  /// succeeded but staged-file cleanup was only partially successful.
  Future<bool> deleteWithRollback(
    Iterable<String> relativePaths,
    Future<void> Function() deleteDatabase,
  );
}
