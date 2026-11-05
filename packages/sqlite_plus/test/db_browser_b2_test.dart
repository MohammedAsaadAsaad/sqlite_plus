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

  Future<List<String>> pinnedRows(String tool, String path, String sql) async {
    final result = await Process.run(tool, [path, sql]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
    final text = result.stdout.toString();
    if (text.isEmpty) return const [];
    return text.split('\n').where((line) => line.isNotEmpty).toList();
  }

  Future<Uint8List> image() async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
    final values = [
      for (var i = 0; i < 80; i++)
        "(${i + 1}, '${i.toString().padLeft(4, '0')}${'x' * 120}')"
    ].join(',');
    await db.execute('INSERT INTO t(id, v) VALUES $values');
    return db.exportImage();
  }

  Future<int> reads(Uint8List bytes, String sql, {bool page = false}) async {
    final db = await SqliteDatabase.openReadOnly(ByteImageStorage(bytes));
    addTearDown(db.close);
    final before = db.pagesRead;
    final result = page ? await db.browse(sql) : await db.query(sql);
    expect(result.rows, isNotEmpty);
    return db.pagesRead - before;
  }

  test('query still reads the whole table when LIMIT is present', () async {
    final bytes = await image();
    final full = await reads(bytes, 'SELECT v FROM t');
    final limited = await reads(bytes, 'SELECT v FROM t LIMIT 100000');
    final window = await reads(bytes, 'SELECT v FROM t LIMIT 1', page: true);
    expect(limited, full);
    expect(window, lessThan(full));
  });

  test('a rowid lower bound stops after the requested window', () async {
    final bytes = await image();
    final fullDb = await SqliteDatabase.openReadOnly(ByteImageStorage(bytes));
    addTearDown(fullDb.close);
    final beforeFull = fullDb.pagesRead;
    final full = await fullDb.query('SELECT id FROM t');
    final fullReads = fullDb.pagesRead - beforeFull;
    expect(full.rows, hasLength(80));

    final db = await SqliteDatabase.openReadOnly(ByteImageStorage(bytes));
    addTearDown(db.close);
    final before = db.pagesRead;
    final window = await db.browse(
        'SELECT id FROM t WHERE rowid > ? ORDER BY rowid LIMIT 5', [10]);
    final windowReads = db.pagesRead - before;
    expect(window.rows.map((row) => row.single).toList(),
        [for (var id = 11; id <= 15; id++) BigInt.from(id)]);
    expect(windowReads, lessThan(fullReads));

    final inclusive = await db
        .browse('SELECT id FROM t WHERE id >= ? ORDER BY id LIMIT 1', [15]);
    expect(inclusive.rows.single.single, BigInt.from(15));
    final descended = await db.query(
        'SELECT id FROM t WHERE rowid > ? ORDER BY rowid DESC LIMIT 3', [75]);
    final descendedBrowse = await db.browse(
        'SELECT id FROM t WHERE rowid > ? ORDER BY rowid DESC LIMIT 3', [75]);
    expect(descendedBrowse.rows, descended.rows);
  });

  test('a paged window matches the pinned CLI', () async {
    final tool = await pinnedCli();
    if (tool == null) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final bytes = await image();
    final directory = Directory.systemTemp.createTempSync('sqlite-plus-b2-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/t.db';
    await File(path).writeAsBytes(bytes);
    final db = await SqliteDatabase.openReadOnly(ByteImageStorage(bytes));
    addTearDown(db.close);
    Future<List<String>> window(String sql,
        [List<Object?> parameters = const []]) async {
      final rows = await db.browse(sql, parameters);
      return rows.rows.map((row) => row.join('|')).toList();
    }

    expect(await window('SELECT id, v FROM t LIMIT 2 OFFSET 3'),
        await pinnedRows(tool, path, 'SELECT id, v FROM t LIMIT 2 OFFSET 3;'));
    expect(
        await window('SELECT id, v FROM t ORDER BY rowid LIMIT 2 OFFSET 3'),
        await pinnedRows(tool, path,
            'SELECT id, v FROM t ORDER BY rowid LIMIT 2 OFFSET 3;'));
    expect(await window('SELECT id, v FROM t LIMIT ? OFFSET ?', [2, 3]),
        await pinnedRows(tool, path, 'SELECT id, v FROM t LIMIT 2 OFFSET 3;'));
    expect(
        await window(
            'SELECT id FROM t WHERE rowid > ? ORDER BY rowid LIMIT 5', [10]),
        await pinnedRows(tool, path,
            'SELECT id FROM t WHERE rowid > 10 ORDER BY rowid LIMIT 5;'));
    expect(
        await window(
            'SELECT id FROM t WHERE rowid >= ? ORDER BY rowid LIMIT 2 OFFSET 3',
            [10]),
        await pinnedRows(tool, path,
            'SELECT id FROM t WHERE rowid >= 10 ORDER BY rowid LIMIT 2 OFFSET 3;'));
    expect(
        await window('SELECT id FROM t WHERE id > ? ORDER BY id LIMIT 5', [70]),
        await pinnedRows(
            tool, path, 'SELECT id FROM t WHERE id > 70 ORDER BY id LIMIT 5;'));
    expect(
        await window(
            'SELECT id FROM t WHERE rowid > ? ORDER BY rowid DESC LIMIT 3',
            [10]),
        await pinnedRows(tool, path,
            'SELECT id FROM t WHERE rowid > 10 ORDER BY rowid DESC LIMIT 3;'));
    expect(await window('SELECT id, v FROM t LIMIT 2 OFFSET 100'), isEmpty);
    expect(await window('SELECT id, v FROM t LIMIT 0'), isEmpty);
    final before = db.pagesRead;
    expect(await window('SELECT id, v FROM t LIMIT 0'), isEmpty);
    expect(db.pagesRead, before);
    expect(await window('SELECT a.v, b.v FROM t a, t b LIMIT 1'),
        await pinnedRows(tool, path, 'SELECT a.v, b.v FROM t a, t b LIMIT 1;'));
    await expectLater(
        db.browse('SELECT v FROM t LIMIT ?'), throwsA(isA<SqlException>()));
    await expectLater(db.browse('SELECT v FROM missing LIMIT 1'),
        throwsA(isA<SqlException>()));
  });

  test('a record above 16 MiB matches the pinned CLI limit', () async {
    final tool = await pinnedCli();
    if (tool == null) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final directory =
        Directory.systemTemp.createTempSync('sqlite-plus-b2-big-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/t.db';
    const length = 16 * 1024 * 1024 + 1;
    final created = await Process.run(tool, [
      path,
      'PRAGMA auto_vacuum=NONE;'
          'CREATE TABLE t(v BLOB);'
          'INSERT INTO t VALUES(zeroblob($length));'
    ]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final bytes = await File(path).readAsBytes();
    final reading = await SqliteDatabase.openReadOnly(ByteImageStorage(bytes));
    addTearDown(reading.close);
    await expectLater(
        reading.query('SELECT v FROM t'), throwsA(isA<FormatException>()));
    final browsed = await SqliteDatabase.openReadOnly(ByteImageStorage(bytes));
    addTearDown(browsed.close);
    final blob = (await browsed.browse('SELECT v FROM t LIMIT 1'))
        .rows
        .single
        .single as Uint8List;
    expect(blob.length, length);
    expect(blob.first, 0);
    expect(blob.last, 0);
    expect(
        await pinnedRows(tool, path,
            'SELECT length(v), hex(substr(v,1,1)), hex(substr(v,length(v),1)) FROM t'),
        ['$length|00|00']);
  });
}
