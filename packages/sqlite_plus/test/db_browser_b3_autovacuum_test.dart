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

  if (!File(cli()).existsSync()) {
    test('pinned sqlite3 is not installed', () {
      markTestSkipped('pinned sqlite3 is not installed');
    });
    return;
  }

  late String tool;
  late Directory scratch;
  var scratchCount = 0;
  setUpAll(() async {
    tool = cli();
    scratch = await Directory.systemTemp.createTemp('sqlite-plus-av-');
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
  });
  tearDownAll(() async {
    if (scratch.existsSync()) await scratch.delete(recursive: true);
  });

  Future<String> pinScript(String sql, {String? database}) async {
    final result = await Process.run(tool, [database ?? ':memory:', sql]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
    return result.stdout.toString().trim();
  }

  Future<String> engineScript(List<String> statements) async {
    final db = await MutableSqliteDatabase.create();
    try {
      final lines = <String>[];
      for (final sql in statements) {
        final writing = sql.contains('=') ||
            sql.startsWith('CREATE') ||
            sql.startsWith('INSERT') ||
            sql.startsWith('DELETE');
        if (writing) await db.execute(sql);
        if (writing &&
            (sql.contains('=') ||
                sql.startsWith('CREATE') ||
                sql.startsWith('INSERT') ||
                sql.startsWith('DELETE'))) {
          continue;
        }
        final result = await db.query(sql);
        for (final row in result.rows) {
          lines.add(row.map((value) => '$value').join('|'));
        }
      }
      return lines.join('\n');
    } finally {
      await db.close();
    }
  }

  Future<void> expectScript(List<String> statements) async {
    final sql = statements.join('; ');
    expect(await engineScript(statements), await pinScript(sql), reason: sql);
  }

  String scratchPath(String name) =>
      '${scratch.path}/${scratchCount++}-$name.db';

  Future<String> pinOn(Uint8List bytes, String sql) async {
    final path = scratchPath('image');
    await File(path).writeAsBytes(bytes, flush: true);
    return pinScript(sql, database: path);
  }

  Future<Uint8List> pinFile(String sql) async {
    final path = scratchPath('native');
    await pinScript(sql, database: path);
    return File(path).readAsBytes();
  }

  test('auto_vacuum statements match the pinned rows', () async {
    await expectScript([
      'PRAGMA auto_vacuum=FULL',
      'PRAGMA auto_vacuum',
    ]);
    await expectScript([
      'PRAGMA auto_vacuum=INCREMENTAL',
      'PRAGMA auto_vacuum',
      'PRAGMA incremental_vacuum',
    ]);
    await expectScript([
      'PRAGMA auto_vacuum=NONE',
      'PRAGMA auto_vacuum',
    ]);
    await expectScript([
      'PRAGMA auto_vacuum=3',
      'PRAGMA auto_vacuum',
    ]);
    await expectScript([
      'PRAGMA auto_vacuum=-1',
      'PRAGMA auto_vacuum',
      'PRAGMA auto_vacuum=nope',
      'PRAGMA auto_vacuum',
      'PRAGMA auto_vacuum=Full',
      'PRAGMA auto_vacuum',
    ]);
    await expectScript([
      'CREATE TABLE t(v)',
      'PRAGMA auto_vacuum=FULL',
      'PRAGMA auto_vacuum',
    ]);
    await expectScript([
      'PRAGMA user_version=3',
      'PRAGMA auto_vacuum=FULL',
      'PRAGMA auto_vacuum',
      'PRAGMA user_version',
    ]);
    await expectScript([
      'PRAGMA auto_vacuum=FULL',
      'PRAGMA auto_vacuum=INCREMENTAL',
      'PRAGMA auto_vacuum',
      'PRAGMA auto_vacuum=NONE',
      'PRAGMA auto_vacuum',
      'PRAGMA auto_vacuum=1',
      'PRAGMA auto_vacuum',
    ]);
    await expectScript([
      'PRAGMA temp.auto_vacuum=FULL',
      'PRAGMA temp.auto_vacuum',
      'PRAGMA main.auto_vacuum',
    ]);
    await expectScript([
      'PRAGMA incremental_vacuum',
      'PRAGMA incremental_vacuum(0)',
      'PRAGMA incremental_vacuum(-1)',
    ]);
  });

  test('FULL, INCREMENTAL, and NONE images match the pinned checks', () async {
    Future<void> compare(String sql, String check) async {
      final db = await MutableSqliteDatabase.create();
      try {
        for (final statement in sql.split(';')) {
          final text = statement.trim();
          if (text.isEmpty) continue;
          await db.execute(text);
        }
        final engine = db.exportImage();
        final native = await pinFile(sql);
        expect(await pinOn(engine, check), await pinOn(native, check),
            reason: sql);
        expect(await pinOn(engine, 'PRAGMA integrity_check'), 'ok',
            reason: sql);
      } finally {
        await db.close();
      }
    }

    const check = 'PRAGMA auto_vacuum; PRAGMA page_count; '
        'PRAGMA freelist_count; PRAGMA integrity_check; SELECT v FROM t';
    await compare(
        'PRAGMA auto_vacuum=FULL; CREATE TABLE t(v); INSERT INTO t VALUES (1);',
        check);
    await compare(
        'PRAGMA auto_vacuum=INCREMENTAL; CREATE TABLE t(v); '
        'INSERT INTO t VALUES (1); PRAGMA incremental_vacuum;',
        check);
    await compare(
        'PRAGMA auto_vacuum=NONE; CREATE TABLE t(v); INSERT INTO t VALUES (1);',
        check);
    await compare(
        'PRAGMA auto_vacuum=FULL; CREATE TABLE t(v); CREATE INDEX i ON t(v); '
        "INSERT INTO t VALUES ('abc');",
        check);
    await compare(
        'PRAGMA auto_vacuum=FULL; CREATE TABLE t(v); '
            'INSERT INTO t VALUES (zeroblob(5000));',
        'PRAGMA auto_vacuum; PRAGMA page_count; PRAGMA freelist_count; '
            'PRAGMA integrity_check; SELECT length(v) FROM t');
    await compare(
        'PRAGMA auto_vacuum=FULL; CREATE TABLE t(v); INSERT INTO t VALUES (1); '
            'DELETE FROM t;',
        'PRAGMA auto_vacuum; PRAGMA page_count; PRAGMA freelist_count; '
            'PRAGMA integrity_check; SELECT count(*) FROM t');

    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('PRAGMA auto_vacuum=FULL');
    await db.execute('CREATE TABLE t(v)');
    await db.execute('CREATE INDEX i ON t(v)');
    await db.execute("INSERT INTO t VALUES ('abc')");
    final native = await pinFile(
        "PRAGMA auto_vacuum=FULL; CREATE TABLE t(v); CREATE INDEX i ON t(v); "
        "INSERT INTO t VALUES ('abc');");
    expect(db.exportImage().sublist(4096, 4116), native.sublist(4096, 4116));
    final overflow = await MutableSqliteDatabase.create();
    addTearDown(overflow.close);
    await overflow.execute('PRAGMA auto_vacuum=FULL');
    await overflow.execute('CREATE TABLE t(v)');
    await overflow.execute('INSERT INTO t VALUES (zeroblob(5000))');
    final nativeOverflow =
        await pinFile('PRAGMA auto_vacuum=FULL; CREATE TABLE t(v); '
            'INSERT INTO t VALUES (zeroblob(5000));');
    expect(overflow.exportImage().sublist(4096, 4126),
        nativeOverflow.sublist(4096, 4126));
  });

  test('corrupt auto-vacuum images match the pinned integrity text', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('PRAGMA auto_vacuum=FULL');
    await db.execute('CREATE TABLE t(v)');
    await db.execute('INSERT INTO t VALUES (1)');
    final corrupt = Uint8List.fromList(db.exportImage())..[4096] = 9;
    expect(await pinOn(corrupt, 'PRAGMA integrity_check; SELECT v FROM t'),
        '*** in database main ***\nFailed to read ptrmap key=3\n1');
    final opened = await MutableSqliteDatabase.fromImage(corrupt);
    addTearDown(opened.close);
    expect((await opened.query('PRAGMA integrity_check')).rows.single.single,
        '*** in database main ***\nFailed to read ptrmap key=3');
    expect((await opened.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);

    final none = await pinFile('CREATE TABLE t(v); INSERT INTO t VALUES (1);');
    final cookie = Uint8List.fromList(none);
    ByteData.sublistView(cookie).setUint32(64, 1);
    expect(
        await pinOn(cookie,
            'PRAGMA auto_vacuum; PRAGMA integrity_check; SELECT v FROM t'),
        '0\n*** in database main ***\n'
        'incremental_vacuum enabled with a max rootpage of zero\n1');
    final readable = await MutableSqliteDatabase.fromImage(cookie);
    addTearDown(readable.close);
    expect(
        (await readable.query('PRAGMA integrity_check')).rows.single.single,
        '*** in database main ***\n'
        'incremental_vacuum enabled with a max rootpage of zero');
    expect((await readable.query('SELECT v FROM t')).rows, [
      [BigInt.one]
    ]);
  });
}
