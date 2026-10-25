import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/src/sql/printf_functions.dart';
import 'package:test/test.dart';

Object? _decode(Object? value) {
  if (value is Map) {
    if (value.containsKey('integer')) {
      return BigInt.parse(value['integer'] as String);
    }
    if (value.containsKey('real')) {
      return value['real'] == 'inf' ? double.infinity : double.negativeInfinity;
    }
    final hex = value['blob'] as String;
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);
  }
  return value;
}

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/printf_oracle.json').readAsStringSync())
          as Map<String, Object?>;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync())
          as Map<String, Object?>;
  test('PRINTF oracle uses the pinned source ID', () {
    expect(fixture['sqlite_version'], manifest['sqlite_version']);
    expect(fixture['source_id'], manifest['source_id']);
  });
  test('PRINTF matches pinned conversions across all database encodings', () {
    final cases = fixture['cases'] as List;
    final failures = <String>[];
    for (var index = 0; index < cases.length; index++) {
      final item = cases[index] as Map;
      final args = (item['arguments'] as List).map(_decode).toList();
      for (final encoding in [1, 2, 3]) {
        // Blob arguments use the database encoding, matching other SQL text
        // coercions. Their ASCII fixture values are only meaningful in UTF-8.
        if (encoding != 1 && args.any((v) => v is Uint8List)) continue;
        try {
          final actual = sqlitePrintf(args, encoding);
          if (actual != item['result']) {
            failures.add(
                '$index ($encoding) $args => $actual; expected ${item['result']}');
          }
        } catch (error) {
          failures.add('$index ($encoding) $args => $error');
        }
      }
    }
    expect(failures.take(30), isEmpty,
        reason: '${failures.length} differences');
  });
  test('PRINTF bounds output before width, precision and repeat allocation',
      () {
    for (final args in [
      ['%16777217s', 'x'],
      ['%.16777217d', BigInt.one],
      ['%.16777217c', 'x'],
      ['%.16777217f', 1.0],
      ['%s%s', 'x' * (8 * 1024 * 1024), 'y' * (8 * 1024 * 1024 + 1)],
    ]) {
      expect(() => sqlitePrintf(args, 1), throwsA(isA<SqlException>()));
    }
    expect((sqlitePrintf(['%16777216s', 'x'], 1) as String).length,
        16 * 1024 * 1024);
  });
  test('byte precision rejects malformed UTF-8 while ! counts code points', () {
    expect(() => sqlitePrintf(['%.1s', 'λ'], 1), throwsA(isA<SqlException>()));
    expect(sqlitePrintf(['%!.1s', 'λ😀'], 1), 'λ');
    expect(sqlitePrintf(['%!.2Q', 'λ😀x'], 1), "'λ😀'");
  });
  test('FORMAT and PRINTF execute SQL and deterministic schema expressions',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect((await db.query('SELECT format(),printf(),format(NULL)')).rows, [
      [null, null, null]
    ]);
    expect(
        (await db.query("SELECT format('%+08d/%!.2s',?,?),printf('%#Q',?)",
                [-42, 'λ😀x', 'a\n\\b']))
            .rows,
        [
          ['-0000042/λ😀', "unistr('a\\u000a\\\\b')"]
        ]);
    await db.execute(
        "CREATE TABLE formatted(n INTEGER, label TEXT GENERATED ALWAYS AS (format('%04d',n)))");
    await db.execute('CREATE INDEX formatted_label ON formatted(label)');
    await db.execute('INSERT INTO formatted(n) VALUES(7),(42)');
    expect(
        (await db.query("SELECT n,label FROM formatted WHERE label='0042'"))
            .rows,
        [
          [BigInt.from(42), '0042']
        ]);
    await expectLater(db.query("SELECT format('%16777217s','x')"),
        throwsA(isA<SqlException>()));
  });
}
