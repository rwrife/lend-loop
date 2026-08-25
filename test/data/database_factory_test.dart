import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/data/database_factory.dart';

void main() {
  test(
    'opens the Drift database in app-private storage and reopens it',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'lend-loop-database-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      LendLoopDatabase database = await openLendLoopDatabase(
        rootDirectory: () async => root,
      );
      await database.customSelect('SELECT 1').getSingle();
      await database.close();

      expect(await File('${root.path}/lend_loop.sqlite').exists(), isTrue);

      database = await openLendLoopDatabase(rootDirectory: () async => root);
      expect(await database.select(database.exchanges).get(), isEmpty);
      await database.close();
    },
  );
}
