import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final cases =
      jsonDecode(File('test/fixtures/select_oracle.json').readAsStringSync())
          as List;
  for (final size in [512, 4096, 65536]) {
    group('SELECT differential $size', () {
      late SqliteDatabase database;
      setUpAll(() async {
        database = await SqliteDatabase.openReadOnly(
            await ReadOnlyFileStorageBackend.open(
                'test/fixtures/sqlite-$size.db'));
      });
      tearDownAll(() => database.close());
      for (final entry in cases.where((c) => c['file'] == 'sqlite-$size.db')) {
        test(entry['sql'] as String, () async {
          final result = await database.query(entry['sql'] as String,
              (entry['parameters'] as List).map(expectedValue).toList());
          expect(result.columns, entry['columns']);
          expect(
              result.rows,
              (entry['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList());
        });
      }
    });
  }
  group('SQL failures and boundaries', () {
    late SqliteDatabase database;
    setUp(() async {
      database = await SqliteDatabase.openReadOnly(
          await ReadOnlyFileStorageBackend.open('test/fixtures/sqlite-512.db'));
    });
    tearDown(() => database.close());
    for (final sql in [
      '',
      'select',
      'select from',
      'select *',
      'select * from missing',
      'select missing from empty',
      'select id from sample where missing=1',
      'select id from sample order by missing',
      'select value from empty order by 0',
      'select id from sample limit null',
      'select id from sample limit 1.5',
      'select id from sample limit id',
      'select ?0',
      'select ?32767',
      'select ?99999999999999999999999999999',
      'select 1; select 2',
      'select id from sample join types',
      'select count(*) from sample',
      'select id from sample group by id',
      'select id from sample union select 1',
      'delete from sample',
      'select x\'q\'',
      "select 'unclosed",
      'select /*unclosed',
      'select 1e',
      'select 0x',
      'select 0xfffffffffffffffff',
      'select :name',
      'select id from sample where id in (1,2)',
    ]) {
      test('rejects $sql', () async {
        await expectLater(database.query(sql), throwsA(isA<SqlException>()));
      });
    }
    test('parameter validation and safe binding', () async {
      await expectLater(
          database.query('select ?', []), throwsA(isA<SqlException>()));
      await expectLater(
          database.query('select 1', [1]), throwsA(isA<SqlException>()));
      await expectLater(
          database.query('select ?', [Object()]), throwsA(isA<SqlException>()));
      final result =
          await database.query('select ? as v', ["'; drop table sample; --"]);
      expect(result.rows.single.single, "'; drop table sample; --");
      expect(
          (await database.query('select id from sample limit 1')).rows.length,
          1);
    });
    test('bound blob results are independent copies', () async {
      final value = Uint8List.fromList([1, 2]);
      final result = await database.query('SELECT ?', [value]);
      value[0] = 99;
      expect(result.rows.single.single, [1, 2]);
    });
    test('closed database refuses queries', () async {
      await database.close();
      await expectLater(database.query('select 1'), throwsStateError);
    });
    test('expression depth bound', () async {
      final sql = 'select ${'(' * 200}1${')' * 200}';
      await expectLater(database.query(sql), throwsA(isA<SqlException>()));
    });
    test('catalog keys and physical column mapping', () {
      final table = DatabaseCatalog.parseTable(
          'CREATE TABLE t(v TEXT, k INTEGER, PRIMARY KEY(k)) WITHOUT ROWID', 2);
      expect(table.storageColumns.map((c) => c.name), ['k', 'v']);
      expect(table.rowidAlias, isNull);
      expect(
          DatabaseCatalog.parseTable(
                  'CREATE TABLE t(id INTEGER PRIMARY KEY DESC)', 2)
              .rowidAlias,
          isNull);
      expect(
          () => DatabaseCatalog.parseTable(
              'CREATE TABLE t(x TEXT COLLATE nocase)', 2),
          throwsA(isA<SqlException>()));
    });
  });
  test('tokenizer quoting, comments, blobs and offsets', () {
    final tokens = SqlTokenizer.tokenize(
        " -- hi\nSELECT \"a\"\"b\", [x], `z`, 'it''s', X'00ff', ?3");
    expect(tokens[0].text, 'SELECT');
    expect(tokens[1].text, 'a"b');
    expect(
        tokens.where((t) => t.kind == SqlTokenKind.string).single.text, "it's");
    expect(
        tokens.where((t) => t.kind == SqlTokenKind.blob).single.text, '00ff');
    expect(() => SqlTokenizer.tokenize('select \u0000'),
        throwsA(isA<SqlException>()));
    expect(() => SqlTokenizer.tokenize(' ' * (1024 * 1024 + 1)),
        throwsA(isA<SqlException>()));
  });
}
