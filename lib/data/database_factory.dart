import 'dart:io';

import 'package:drift/native.dart';
import 'package:lend_loop/data/database.dart';
import 'package:path_provider/path_provider.dart';

typedef DatabaseRootDirectoryProvider = Future<Directory> Function();

Future<LendLoopDatabase> openLendLoopDatabase({
  DatabaseRootDirectoryProvider? rootDirectory,
}) async {
  final Directory root =
      await (rootDirectory ?? getApplicationSupportDirectory)();
  await root.create(recursive: true);
  return LendLoopDatabase(
    NativeDatabase.createInBackground(File('${root.path}/lend_loop.sqlite')),
  );
}
