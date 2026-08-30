import 'dart:async';
import 'dart:io';

import 'package:lend_loop/domain/exchange_domain.dart';

typedef PrivateStorageBoundary = Future<void> Function();

final Map<String, Future<void>> _tails = <String, Future<void>>{};
final Object _activeRootKey = Object();

/// Runs app-controlled private-file work serially for one canonical root.
///
/// Android/iOS application-support storage is trusted not to be mutated by an
/// adversarial external process. Pure Dart cannot make path validation and a
/// later filesystem syscall atomic; callers therefore revalidate at each
/// operation boundary, while this lock closes races between all app-controlled
/// backup, restore, cleanup, and photo operations.
Future<T> withPrivateStorage<T>(
  Future<Directory> Function() rootDirectory,
  Future<T> Function(Directory root, PrivateStorageBoundary revalidate) action,
) async {
  final Directory suppliedRoot = await rootDirectory();
  final String canonical = await _canonicalRoot(suppliedRoot);
  final Directory root = Directory(canonical);
  PrivateStorageBoundary boundary() =>
      () => _validateSameRoot(suppliedRoot, canonical);
  if (Zone.current[_activeRootKey] == canonical) {
    return action(root, boundary());
  }

  final Completer<void> turn = Completer<void>();
  final Future<void> previous = _tails[canonical] ?? Future<void>.value();
  _tails[canonical] = turn.future;
  await previous;
  try {
    await _validateSameRoot(suppliedRoot, canonical);
    return await runZoned(
      () => action(root, boundary()),
      zoneValues: <Object, Object>{_activeRootKey: canonical},
    );
  } finally {
    turn.complete();
    if (identical(_tails[canonical], turn.future)) {
      final Future<void>? removed = _tails.remove(canonical);
      assert(removed != null);
    }
  }
}

Future<String> containedPrivatePath(
  Directory root,
  String relativePath,
  PrivateStorageBoundary revalidate,
) async {
  final String safe = validateRelativePath(relativePath);
  await revalidate();
  String current = root.absolute.path;
  for (final String component in safe.split('/')) {
    current = '$current${Platform.pathSeparator}$component';
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw InvalidValue('Private path contains a symbolic link.');
    }
  }
  await revalidate();
  return current;
}

Future<String> _canonicalRoot(Directory root) async {
  final String absolute = root.absolute.path;
  final FileSystemEntityType type = await FileSystemEntity.type(
    absolute,
    followLinks: false,
  );
  if (type != FileSystemEntityType.directory) {
    throw InvalidValue('Private storage root must be a real directory.');
  }
  return root.resolveSymbolicLinks();
}

Future<void> _validateSameRoot(Directory root, String expected) async {
  if (await _canonicalRoot(root) != expected) {
    throw InvalidValue('Private storage root changed during the operation.');
  }
}
