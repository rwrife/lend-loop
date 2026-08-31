import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  for (final int version in <int>[1, 2, 3]) {
    test('opens and verifies committed schema v$version seed', () async {
      final String fixture = File('test/fixtures/database/v$version.sql')
          .readAsStringSync();
      final LendLoopDatabase database = LendLoopDatabase(
        NativeDatabase.memory(
          setup: (sqlite.Database raw) {
            for (final String statement in fixture.split(';')) {
              if (statement.trim().isNotEmpty) raw.execute(statement);
            }
          },
        ),
      );
      addTearDown(database.close);
      final DriftExchangeRepository repository = DriftExchangeRepository(
        database,
      );

      final Exchange exchange = (await repository.get(
        ExchangeId('fixture-exchange'),
      ))!;
      expect(exchange.status, ExchangeStatus.open);
      expect(
        (await repository.events(exchange.id)).single.id.value,
        'fixture-event',
      );
      expect(
        (await database.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        3,
      );
      expect(
        (await database.customSelect('PRAGMA foreign_key_check').get()),
        isEmpty,
      );

      final List<Attachment> attachments = await repository.attachments(
        exchange.id,
      );
      expect(attachments, version == 1 ? isEmpty : hasLength(1));
      expect(
        await repository.getReminder(exchange.id),
        version == 3 ? isNotNull : isNull,
        reason:
            'v2 reminder rows are intentionally rebuilt because their '
            'payload and schedule were incomplete',
      );
    });
  }
}
