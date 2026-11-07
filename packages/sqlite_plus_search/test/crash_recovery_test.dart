import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

import 'support/fault_storage.dart';

Future<MutableSqliteDatabase> open(FaultStorage data, FaultStorage log) async =>
    MutableSqliteDatabase.fromJournalPager(
        await RollbackJournalPager.open(data, log));

void main() {
  const learning = AdaptiveLearningConfig(enabled: true);
  for (final scenario in ['rebuild', 'replay', 'feedback', 'fuzzy']) {
    for (final immediate in [false, true]) {
      for (final journalMode in ['delete', 'persist']) {
        test(
            '$scenario recovers at every storage operation; immediate persistence=$immediate, journal=$journalMode',
            () async {
          final seed = await openInMemory();
          await seed
              .execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
          await seed
              .execute("INSERT INTO docs VALUES (1,'old milk'),(2,'old tea')");
          final initial =
              await SqlitePlusSearch.open(database: seed, learning: learning);
          await initial.indexTable(
              table: 'docs',
              primaryKey: 'id',
              textColumns: ['body'],
              autoUpdate: scenario == 'replay');
          String? searchId;
          if (scenario == 'feedback') {
            searchId = (await initial.search('milk', table: 'docs')).searchId;
          } else {
            await seed.execute("UPDATE docs SET body='new milk' WHERE id=1");
          }
          final image = seed.exportImage();
          await seed.close();
          Future<void> action(SqlitePlusSearch search) async {
            if (scenario == 'rebuild') {
              await search.indexTable(
                  table: 'docs', primaryKey: 'id', textColumns: ['body']);
            } else if (scenario == 'replay') {
              await search.search('new', table: 'docs');
            } else if (scenario == 'fuzzy') {
              await search.search('milkk',
                  table: 'docs', fuzzy: const FuzzySearchConfig(learnAfter: 1));
            } else {
              await search.feedback.submit(
                  searchId: searchId!,
                  documentId: '1',
                  relevance: Relevance.high);
            }
          }

          Future<(MutableSqliteDatabase, SqlitePlusSearch)> setup(
              Faults faults, FaultStorage data, FaultStorage log) async {
            final db = await open(data, log);
            await db.execute('PRAGMA journal_mode=$journalMode');
            final search =
                await SqlitePlusSearch.open(database: db, learning: learning);
            faults.operations = 0;
            return (db, search);
          }

          final baseline = Faults()..immediatePersistence = immediate;
          final baselineData = FaultStorage(image, baseline),
              baselineLog = FaultStorage(Uint8List(0), baseline);
          final (baselineDb, baselineSearch) =
              await setup(baseline, baselineData, baselineLog);
          await action(baselineSearch);
          final operations = baseline.operations;
          expect(operations, greaterThan(0));
          print(
              '$scenario $journalMode immediate=$immediate fault points: $operations');
          await baselineDb.close();
          for (var point = 1; point <= operations; point++) {
            final faults = Faults()..immediatePersistence = immediate;
            final data = FaultStorage(image, faults),
                log = FaultStorage(Uint8List(0), faults);
            final (_, search) = await setup(faults, data, log);
            faults.failAfter = point;
            await expectLater(action(search), throwsA(isA<PowerLoss>()),
                reason: '$scenario operation $point/$operations');
            data.losePower();
            log.losePower();
            faults.failAfter = null;
            final recovered = await open(data, log);
            final restored = await SqlitePlusSearch.open(
                database: recovered, learning: learning);
            await restored.verifyIndex(table: 'docs');
            if (scenario == 'fuzzy') {
              final exists = await recovered.query(
                  "SELECT name FROM sqlite_schema WHERE name='_sps_fuzzy_learning'");
              final observations = exists.rows.isEmpty
                  ? 0
                  : (await recovered
                          .query('SELECT count(*) FROM _sps_fuzzy_learning'))
                      .rows
                      .single
                      .single as BigInt;
              final next = (await recovered
                      .query('SELECT next_search FROM _sps_state WHERE id=1'))
                  .rows
                  .single
                  .single;
              expect(observations == BigInt.one, next == BigInt.two,
                  reason:
                      'observations and search counter must commit together');
              expect(
                  (await restored.search('milkk',
                          table: 'docs',
                          fuzzy: const FuzzySearchConfig(learnAfter: 1)))
                      .hits
                      .single
                      .documentId,
                  '1');
            } else if (scenario == 'feedback') {
              final weights = (await restored.feedback
                  .exportModel(table: 'docs'))['weights'] as List<double>;
              final used = (await recovered.query(
                      'SELECT used FROM _sps_feedback WHERE search_id=?',
                      [searchId]))
                  .rows
                  .single
                  .single;
              expect(weights[0] > 0, used == BigInt.one,
                  reason: 'weights and label must commit together at $point');
              if (used == BigInt.zero) {
                await restored.feedback.submit(
                    searchId: searchId!,
                    documentId: '1',
                    relevance: Relevance.high);
              }
            } else {
              final body = (await recovered
                      .query('SELECT body FROM _sps_1_fts WHERE rowid=1'))
                  .rows
                  .single
                  .single;
              expect(body, anyOf('old milk', 'new milk'),
                  reason: 'no partial index at $point');
              if (scenario == 'replay') {
                final events =
                    (await recovered.query('SELECT * FROM _sps_1_pending'))
                        .rows;
                expect(events.isEmpty, body == 'new milk',
                    reason:
                        'index and log acknowledgment must commit together');
              } else {
                await restored.indexTable(
                    table: 'docs', primaryKey: 'id', textColumns: ['body']);
              }
              expect(
                  (await restored.search('new', table: 'docs'))
                      .hits
                      .single
                      .documentId,
                  '1');
            }
            await recovered.close();
            data.losePower();
            log.losePower();
            final twice = await open(data, log);
            expect(
                (await twice.query('PRAGMA integrity_check'))
                    .rows
                    .single
                    .single,
                'ok');
            await twice.close();
          }
        }, timeout: const Timeout(Duration(minutes: 3)));
      }
    }
  }
}
