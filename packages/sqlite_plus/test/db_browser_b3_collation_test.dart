import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  if (!File(cli()).existsSync()) {
    test('pinned sqlite3 is not installed', () {
      markTestSkipped('pinned sqlite3 is not installed');
    });
    return;
  }

  Future<String> pinnedCli() async {
    final tool = cli();
    expect(File(tool).existsSync(), isTrue);
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  Future<String> cell(String tool, String sql) async {
    final result = await Process.run(tool, [':memory:', sql]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
    return result.stdout.toString().trim();
  }

  test('built-in collations match and ICU stays absent', () async {
    final tool = await pinnedCli();
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final shared = <String, String>{
      "SELECT 'a'='A' COLLATE NOCASE": '1',
      "SELECT 'a'='A' COLLATE BINARY": '0',
      "SELECT 'a '='a' COLLATE RTRIM": '1',
      "SELECT 'á'<'b' COLLATE NOCASE": '0',
    };
    for (final entry in shared.entries) {
      expect(await cell(tool, entry.key), entry.value, reason: entry.key);
      final rows = await db.query(entry.key);
      final value = rows.rows.single.single;
      final text = value is BigInt ? value.toString() : value.toString();
      expect(text, entry.value, reason: entry.key);
    }
    final icu = await Process.run(
        tool, [':memory:', 'CREATE TABLE t(v TEXT COLLATE ICU)']);
    expect(icu.exitCode, isNonZero);
    expect(icu.stderr.toString(), contains('no such collation sequence: ICU'));
    await expectLater(
        db.execute('CREATE TABLE t(v TEXT COLLATE ICU)'),
        throwsA(isA<SqlException>()
            .having((error) => error.message, 'message', 'Unknown collation')));
    final compare =
        await Process.run(tool, [':memory:', "SELECT 'a'='A' COLLATE ICU"]);
    expect(compare.exitCode, isNonZero);
    expect(
        compare.stderr.toString(), contains('no such collation sequence: ICU'));
    await expectLater(
        db.query("SELECT 'a'='A' COLLATE ICU"),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such collation: ICU')));
    expect(await cell(tool, "SELECT 'a' COLLATE ICU"), 'a');
    await expectLater(
        db.query("SELECT 'a' COLLATE ICU"),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such collation: ICU')));
    final locale =
        await Process.run(tool, [':memory:', "SELECT 'a'='A' COLLATE en_US"]);
    expect(locale.exitCode, isNonZero);
    expect(locale.stderr.toString(),
        contains('no such collation sequence: en_US'));
    await expectLater(
        db.query("SELECT 'a'='A' COLLATE en_US"),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such collation: en_US')));
    final empty =
        await Process.run(tool, [':memory:', "SELECT 'a'='b' COLLATE \"\""]);
    expect(empty.exitCode, isNonZero);
    expect(empty.stderr.toString(), contains('no such collation sequence:'));
    final list = await Process.run(tool, [':memory:', 'PRAGMA collation_list']);
    expect(list.exitCode, 0);
    final names = list.stdout.toString();
    expect(names, contains('BINARY'));
    expect(names, contains('NOCASE'));
    expect(names, contains('RTRIM'));
    expect(names, contains('decimal'));
    expect(names, contains('uint'));
    final engineList = await db.query('PRAGMA collation_list');
    final engineNames = engineList.rows.map((row) => row[1].toString()).toSet();
    expect(engineNames, containsAll(['BINARY', 'NOCASE', 'RTRIM']));
    expect(engineNames.contains('decimal'), isFalse);
    expect(engineNames.contains('uint'), isFalse);
    expect((await db.query("SELECT 'a'='A' COLLATE NOCASE")).rows, [
      [BigInt.one]
    ]);
  });
}
