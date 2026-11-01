import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  Future<String?> pinnedCli() async {
    final tool = cli();
    if (!File(tool).existsSync()) return null;
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  Future<String> pinnedCell(String tool, String sql) async {
    final result = await Process.run(tool, [':memory:', sql]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
    return result.stdout.toString().trimRight();
  }

  String textFromHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    try {
      final decoded = utf8.decode(bytes);
      final encoded = utf8.encode(decoded);
      if (encoded.length == bytes.length) {
        var same = true;
        for (var i = 0; i < bytes.length; i++) {
          if (encoded[i] != bytes[i]) {
            same = false;
            break;
          }
        }
        if (same) return decoded;
      }
    } on FormatException {
      // An invalid UTF-8 indent byte stays a code unit.
    }
    return String.fromCharCodes(bytes);
  }

  test('json_pretty matches the pinned CLI text', () async {
    final tool = await pinnedCli();
    expect(tool, isNotNull);
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const expressions = <String>[
      r'''json_pretty('{"a":1}')''',
      r'''json_pretty('{}')''',
      r'''json_pretty('[]')''',
      r'''json_pretty('{"a":[1,{"b":true}],"c":null}')''',
      r'''json_pretty('[1,{"b":[]}]')''',
      r'''json_pretty('{"a":1,"a":2}')''',
      r'''json_pretty('{"a":1 /*c*/}')''',
      r'''json_pretty('{"a":"line\n"}')''',
      r'''json_pretty('{"ä":"β"}')''',
      r'''json_pretty('{"a":1}','  ')''',
      r'''json_pretty('{"a":1}','')''',
      r'''json_pretty('{"a":1}', NULL)''',
      r'''json_pretty('{"a":[1]}', 1.5)''',
      r'''json_pretty('[1,2]', 2)''',
      r'''json_pretty('{"a":1}', x'2020')''',
      r'''json_pretty('{"a":1}', x'ff')''',
      r'''json_pretty('{"a":1}', char(0))''',
      r'''json_pretty('{"a":1}', 'x'||char(0)||'y')''',
      r'''json_pretty(NULL)''',
      r'''json_pretty(1)''',
      r'''json_pretty(1.0)''',
      r'''json_pretty(10.0)''',
      r'''json_pretty(1e2)''',
      r'''json_pretty(-0.0)''',
      r'''json_pretty(x'7b2261223a317d')''',
      r'''json_pretty(jsonb('{"z":[true]}'))''',
      r'''json_pretty('[[[]]]')''',
    ];
    for (final expression in expressions) {
      final sql = 'SELECT $expression';
      final engine = (await db.query(sql)).rows.single.single;
      final pinned = await pinnedCell(
          tool!,
          "SELECT CASE WHEN ($expression) IS NULL THEN 'NULL' "
          "ELSE hex($expression) END");
      if (pinned == 'NULL') {
        expect(engine, isNull, reason: expression);
      } else {
        expect(engine, textFromHex(pinned), reason: expression);
      }
    }
    expect((await db.query("SELECT json_pretty('{\"a\":1}') -> 'a'")).rows, [
      ['1']
    ]);
    expect(
        await pinnedCell(
            tool!, "SELECT quote(json_pretty('{\"a\":1}') -> 'a');"),
        "'1'");
    expect((await db.query("SELECT json_pretty('{\"a\":1}') ->> 'a'")).rows, [
      [BigInt.one]
    ]);
    expect(
        await pinnedCell(
            tool, "SELECT typeof(json_pretty('{\"a\":1}') ->> 'a');"),
        'integer');
    expect(
        (await db.query(
                r'''SELECT typeof(json_pretty('{"a":1}')), json_type(json_pretty('{"a":1}'))'''))
            .rows,
        [
          ['text', 'object']
        ]);
  });

  test(
      'json_pretty rejects malformed input, the wrong arity, and oversize output',
      () async {
    final tool = await pinnedCli();
    expect(tool, isNotNull);
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await expectLater(
        db.query("SELECT json_pretty('{')"),
        throwsA(isA<SqlException>()
            .having((error) => error.message, 'message', 'malformed JSON')));
    final malformed =
        await Process.run(tool!, [':memory:', "SELECT json_pretty('{');"]);
    expect(malformed.exitCode, isNot(0));
    expect(malformed.stderr.toString(), contains('malformed JSON'));
    await expectLater(
        db.query('SELECT json_pretty()'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'Invalid arguments to json_pretty')));
    await expectLater(
        db.query("SELECT json_pretty('{}',' ','x')"),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'Invalid arguments to json_pretty')));
    final arity =
        await Process.run(tool, [':memory:', 'SELECT json_pretty();']);
    expect(arity.exitCode, isNot(0));
    expect(arity.stderr.toString(), contains('wrong number of arguments'));
    // JSON input is capped at 1 MiB, so the 16 MiB output cap is reached
    // through the indent string. pretty('[1]', indent) is indent.length + 5.
    const limit = 16 * 1024 * 1024;
    final pretty =
        (await db.query('SELECT json_pretty(?, ?)', ['[1]', ' ' * (limit - 5)]))
            .rows
            .single
            .single as String;
    expect(pretty.length, limit);
    expect(pretty.startsWith('[\n'), isTrue);
    expect(pretty.endsWith('1\n]'), isTrue);
    await expectLater(
        db.query('SELECT json_pretty(?, ?)', ['[1]', ' ' * (limit - 4)]),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'Function output limit exceeded')));
  });

  test('json() stays compact after json_pretty is registered', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect((await db.query(r'''SELECT json('{"a":1}')''')).rows, [
      ['{"a":1}']
    ]);
    final utf16 = await MutableSqliteDatabase.create(encoding: 2);
    addTearDown(utf16.close);
    final bytes = Uint8List(14);
    final data = ByteData.sublistView(bytes);
    const text = '{"a":1}';
    for (var i = 0; i < text.length; i++) {
      data.setUint16(i * 2, text.codeUnitAt(i), Endian.little);
    }
    expect(
        (await utf16.query('SELECT json_pretty(?)', [bytes]))
            .rows
            .single
            .single,
        '{\n    "a": 1\n}');
  });
}
