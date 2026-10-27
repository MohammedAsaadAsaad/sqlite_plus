import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

Object? _oracleValue(dynamic value) {
  if (value is Map && value.containsKey('float')) {
    return double.parse(value['float'] as String);
  }
  return expectedValue(value);
}

void main() {
  final cases =
      jsonDecode(File('test/fixtures/json_oracle.json').readAsStringSync())
          as List;
  for (final encoding in [1, 2, 3]) {
    group('JSON pinned encoding $encoding', () {
      late MutableSqliteDatabase db;
      setUpAll(() async {
        db = await MutableSqliteDatabase.create(encoding: encoding);
      });
      tearDownAll(() => db.close());
      for (final (index, entry)
          in cases.where((entry) => entry['encoding'] == encoding).indexed) {
        final sql = entry['sql'] as String;
        final label = sql.length > 140 ? '${sql.substring(0, 140)}…' : sql;
        test('${index + 1}: $label', () async {
          if (entry.containsKey('error')) {
            await expectLater(db.query(sql), throwsA(isA<SqlException>()));
          } else {
            expect(
                (await db.query(sql)).rows,
                (entry['rows'] as List)
                    .map((row) => (row as List).map(_oracleValue).toList())
                    .toList());
          }
        });
      }
    });
  }

  test('JSON constructors bind parameters instead of concatenating text',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final row = (await db.query(
            'SELECT json_array(?, ?, ?), json_object(?, ?), json_extract(?, ?), json_array_length(?, ?)',
            [1, null, 'x', 'a', 1, '{"a":[2,3]}', r'$.a', '[1,2,3]', r'$']))
        .rows
        .single;
    expect(row, [
      '[1,null,"x"]',
      '{"a":1}',
      '[2,3]',
      BigInt.from(3),
    ]);
  });

  test('JSON edit and path errors use the SQLite messages', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    Future<String> message(String sql) async {
      try {
        await db.query(sql);
      } on SqlException catch (error) {
        return error.message;
      }
      fail('expected SqlException for $sql');
    }

    expect(await message("SELECT json('nope')"), 'malformed JSON');
    expect(await message("SELECT json_extract('{}','')"), "bad JSON path: ''");
    expect(await message("SELECT json_extract('{}', 'a''b')"),
        "bad JSON path: 'a''b'");
    expect(await message("SELECT json_set('{}','\$.a')"),
        'json_set() needs an odd number of arguments');
    expect(await message("SELECT jsonb_set('{}','\$.a')"),
        'json_set() needs an odd number of arguments');
    expect(await message("SELECT json_object('a')"),
        'json_object() requires an even number of arguments');
    expect(await message('SELECT json_object(1,2)'),
        'json_object() labels must be TEXT');
    expect(await message("SELECT json_quote(x'ff')"),
        'JSON cannot hold BLOB values');
    expect(await message("SELECT json_valid('{}', 0)"),
        'FLAGS parameter to json_valid() must be between 1 and 15');
    expect(await message('SELECT json()'), 'Invalid arguments to json');
  });

  test('depth 1000 succeeds, depth 1001 and a raw NUL fail', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final deep = '${'[' * 1000}${']' * 1000}';
    final deeper = '${'[' * 1001}${']' * 1001}';
    expect(
        (await db.query('SELECT json_valid(?), length(json(?))', [deep, deep]))
            .rows,
        [
          [BigInt.one, BigInt.from(2000)]
        ]);
    expect((await db.query('SELECT json_valid(?)', [deeper])).rows, [
      [BigInt.zero]
    ]);
    await expectLater(
        db.query('SELECT json(?)', [deeper]), throwsA(isA<SqlException>()));
    expect((await db.query("SELECT json('\"\\u0000\"')")).rows, [
      [r'"\u0000"']
    ]);
    expect(
        (await db.query("SELECT json_extract('\"\\u0000\"','\$')"))
            .rows
            .single
            .single,
        '\u0000');
    await expectLater(
        db.query('SELECT json(?)', ['[\u0000]']), throwsA(isA<SqlException>()));
    expect((await db.query('SELECT json_valid(?)', ['[\u0000]'])).rows, [
      [BigInt.zero]
    ]);
  });

  test('JSON text accepts 1 MiB and rejects one more byte', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final atLimit = '"${'a' * (1024 * 1024 - 2)}"';
    final overLimit = '"${'a' * (1024 * 1024 - 1)}"';
    expect(atLimit.length, 1024 * 1024);
    expect(overLimit.length, 1024 * 1024 + 1);
    expect(
        (await db.query(
                'SELECT json_valid(?), length(json(?))', [atLimit, atLimit]))
            .rows,
        [
          [BigInt.one, BigInt.from(atLimit.length)]
        ]);
    expect((await db.query('SELECT json_valid(?)', [overLimit])).rows, [
      [BigInt.zero]
    ]);
    await expectLater(
        db.query('SELECT json(?)', [overLimit]),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'JSON input exceeds 1 MiB limit')));
  });

  test(
      'json_quote accepts the 16 MiB output boundary and rejects the next byte',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const limit = 16 * 1024 * 1024;
    final atLimit = 'a' * (limit - 2);
    final quoted = (await db.query('SELECT json_quote(?)', [atLimit]))
        .rows
        .single
        .single as String;
    expect(quoted.length, limit);
    expect(quoted.startsWith('"'), isTrue);
    await expectLater(
        db.query('SELECT json_quote(?)', ['a' * (limit - 1)]),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'Function output limit exceeded')));
  });

  test('a constant json_each joins a user table and a column argument fails',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT)');
    await db.execute("INSERT INTO docs VALUES(1,'a'),(2,'b'),(3,'c')");
    expect((await db.query('''
      SELECT docs.id, e.value
      FROM docs JOIN json_each('{"a":10,"b":20}') AS e ON docs.label = e.key
      ORDER BY docs.id
      ''')).rows, [
      [BigInt.one, BigInt.from(10)],
      [BigInt.two, BigInt.from(20)]
    ]);
    expect((await db.query('SELECT key FROM json_each(?)', ['{"a":1}'])).rows, [
      ['a']
    ]);
    await expectLater(
        db.query('SELECT value FROM docs, json_each(docs.label)'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'Virtual table argument must be constant')));
    expect(
        (await db.query("SELECT * FROM json_each('{\"a\":1}')"))
            .rows
            .single
            .length,
        8);
  });
}
