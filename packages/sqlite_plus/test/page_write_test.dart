import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'rollback_pager_test.dart'
    show CrashController, ModelFile, SimulatedCrash;

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  Future<void> expectPinned(Uint8List image, String sql) async {
    final tool = cli();
    if (!File(tool).existsSync()) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final file = File(
        '${Directory.systemTemp.path}/sqlite_plus_page_${image.length}_${image.hashCode}.db');
    await file.writeAsBytes(image, flush: true);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final check = await Process.run(tool, [file.path, sql]);
    expect(check.exitCode, 0, reason: '${check.stderr}\n${check.stdout}');
    expect(check.stdout.toString().trim().split('\n').first.trim(), 'ok');
  }

  test('a rowid insert splits a leaf and still opens in SQLite', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    final values = [
      for (var i = 0; i < 200; i++) "('${i.toString().padLeft(24, '0')}')"
    ].join(',');
    await db.execute('INSERT INTO t(v) VALUES $values');
    await db.execute("INSERT INTO t(v) VALUES('tail')");
    final image = db.exportImage();
    final pageSize = DatabaseHeader.decode(image).pageSize;
    final interior = List.generate(image.length ~/ pageSize - 1,
        (index) => image[(index + 1) * pageSize] == 5);
    expect(interior, contains(true));
    expect((await db.query('SELECT count(*) FROM t')).rows.single.single,
        BigInt.from(201));
    expect((await db.query('PRAGMA integrity_check')).rows.single.single, 'ok');
    await expectPinned(
        image, 'PRAGMA integrity_check; SELECT count(*) FROM t;');
  });

  test('deleting every row leaves an empty tree that passes integrity_check',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    final values = [
      for (var i = 0; i < 200; i++) "('${i.toString().padLeft(24, '0')}')"
    ].join(',');
    await db.execute('INSERT INTO t(v) VALUES $values');
    expect((await db.execute('DELETE FROM t')).changes, 200);
    expect((await db.query('SELECT count(*) FROM t')).rows.single.single,
        BigInt.zero);
    expect((await db.query('PRAGMA integrity_check')).rows.single.single, 'ok');
    await expectPinned(
        db.exportImage(), 'PRAGMA integrity_check; SELECT count(*) FROM t;');
  });

  test('a same-length overflow change rewrites only the affected page',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    final original = 'a' * 7000;
    await db.execute('INSERT INTO t(v) VALUES(?)', [original]);
    final before = db.exportImage();
    final changed = original.replaceRange(5000, 5100, 'b' * 100);
    await db.execute('UPDATE t SET v=?', [changed]);
    final after = db.exportImage();
    expect(after.length, before.length);
    final pageSize = DatabaseHeader.decode(after).pageSize;
    final different = <int>[];
    for (var page = 0; page < after.length ~/ pageSize; page++) {
      final start = page * pageSize;
      var same = true;
      for (var i = 0; i < pageSize; i++) {
        if (before[start + i] != after[start + i]) {
          same = false;
          break;
        }
      }
      if (!same) different.add(page + 1);
    }
    expect(different, contains(1));
    expect(different.length, lessThan(4));
    expect((await db.query('SELECT v FROM t')).rows.single.single, changed);
    expect((await db.query('PRAGMA integrity_check')).rows.single.single, 'ok');
    await expectPinned(
        after, 'PRAGMA integrity_check; SELECT length(v) FROM t;');
  });

  test('expression and partial index pages stay when their keys do not change',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a, b, c)');
    await db.execute('CREATE INDEX expression_ab ON t(a+b)');
    await db.execute('CREATE INDEX partial_a ON t(a) WHERE a>0');
    await db.execute("INSERT INTO t VALUES(1, 2, 'old')");
    final before = db.exportImage();
    final beforePages = await _indexPages(before, 't');
    await db.execute("UPDATE t SET c='new' WHERE a=1");
    final after = db.exportImage();
    final afterPages = await _indexPages(after, 't');
    expect(afterPages.keys, beforePages.keys);
    for (final root in beforePages.keys) {
      expect(afterPages[root], beforePages[root]);
    }
    expect((await db.query('SELECT c FROM t WHERE a+b=3')).rows, [
      ['new']
    ]);
    expect((await db.query('SELECT c FROM t WHERE a=1')).rows, [
      ['new']
    ]);
    await db.execute('UPDATE t SET a=4 WHERE c=?', ['new']);
    expect((await db.query('SELECT a, b FROM t WHERE a+b=6')).rows, [
      [BigInt.from(4), BigInt.two]
    ]);
    expect((await db.query('SELECT a FROM t WHERE a>0')).rows, [
      [BigInt.from(4)]
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows.single.single, 'ok');
  });

  test('delete then insert of the same size reuses the freelist', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    final values = [
      for (var i = 0; i < 200; i++) "('${i.toString().padLeft(24, '0')}')"
    ].join(',');
    await db.execute('INSERT INTO t(v) VALUES $values');
    final before = (await db.query('PRAGMA page_count')).rows.single.single;
    expect(before as BigInt, greaterThan(BigInt.two));
    await db.execute('DELETE FROM t');
    expect((await db.query('PRAGMA page_count')).rows.single.single, before);
    expect((await db.query('PRAGMA freelist_count')).rows.single.single,
        greaterThan(BigInt.zero));
    await db.execute('INSERT INTO t(v) VALUES $values');
    expect((await db.query('PRAGMA page_count')).rows.single.single, before);
    expect((await db.query('SELECT count(*) FROM t')).rows.single.single,
        BigInt.from(200));
    expect((await db.query('PRAGMA integrity_check')).rows.single.single, 'ok');
  });

  test('unsupported shapes keep a readable compact image', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE wr(a PRIMARY KEY, b) WITHOUT ROWID');
    await db.execute("INSERT INTO wr VALUES('k', 'v')");
    await db.execute("UPDATE wr SET b='w' WHERE a='k'");
    expect((await db.query('SELECT b FROM wr WHERE a=?', ['k'])).rows, [
      ['w']
    ]);
    await db.execute('CREATE TABLE keyed(id INTEGER PRIMARY KEY, v)');
    await db.execute('INSERT INTO keyed(v) VALUES(1)');
    await db.execute('UPDATE keyed SET v=2 WHERE id=1');
    expect((await db.query('SELECT v FROM keyed WHERE id=1')).rows, [
      [BigInt.two]
    ]);
    await db.execute('CREATE TABLE trig(v)');
    await db.execute(
        "CREATE TRIGGER tr AFTER INSERT ON trig BEGIN UPDATE trig SET v=v||'!'; END");
    await db.execute("INSERT INTO trig VALUES('z')");
    expect((await db.query('SELECT v FROM trig')).rows, [
      ['z!']
    ]);
    await db.execute('CREATE VIEW seen AS SELECT v FROM trig');
    await db.execute("UPDATE trig SET v='y!' WHERE v='z!'");
    expect((await db.query('SELECT v FROM seen')).rows, [
      ['y!']
    ]);
    expect((await db.query('SELECT value FROM generate_series(1,2)')).rows, [
      [BigInt.one],
      [BigInt.two]
    ]);
    await db.execute('CREATE VIRTUAL TABLE f USING fts5(body)');
    await db.execute("INSERT INTO f(body) VALUES('hello')");
    expect((await db.query("SELECT body FROM f WHERE f MATCH 'hello'")).rows, [
      ['hello']
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows.single.single, 'ok');
    final vacuum = Uint8List.fromList(db.exportImage());
    ByteData.sublistView(vacuum).setUint32(52, 1);
    await expectLater(
        MutableSqliteDatabase.fromImage(vacuum), throwsUnsupportedError);
  });

  test('journal and WAL crashes recover the previous incremental image',
      () async {
    final seed = await MutableSqliteDatabase.create();
    await seed.execute('CREATE TABLE t(v)');
    await seed.execute("INSERT INTO t VALUES('a')");
    final baseline = seed.exportImage();
    await seed.close();

    Future<void> crashStep(String sql, List<Object?> parameters) async {
      final probe = CrashController();
      final pager = await RollbackJournalPager.open(
          ModelFile(baseline, probe), ModelFile(Uint8List(0), probe));
      final db = await MutableSqliteDatabase.fromJournalPager(pager);
      await db.execute(sql, parameters);
      final operations = probe.operations;
      await db.close();
      expect(operations, greaterThan(0));
      final faults = CrashController()..crashAt = 1;
      final file = ModelFile(baseline, faults);
      final log = ModelFile(Uint8List(0), faults);
      final crashing = await RollbackJournalPager.open(file, log);
      final writer = await MutableSqliteDatabase.fromJournalPager(crashing);
      await expectLater(
          writer.execute(sql, parameters), throwsA(isA<SimulatedCrash>()));
      file.crash();
      log.crash();
      faults.crashAt = null;
      final recovered = await RollbackJournalPager.open(file, log);
      expect(await recovered.readImage(), baseline);
      await recovered.close();
      await writer.close();
    }

    await crashStep("INSERT INTO t VALUES('b')", const []);
    await crashStep('DELETE FROM t', const []);
    final wide = await MutableSqliteDatabase.create();
    await wide.execute('CREATE TABLE t(v)');
    await wide.execute('INSERT INTO t(v) VALUES(?)', ['a' * 7000]);
    final wideBase = wide.exportImage();
    await wide.close();
    final probe = CrashController();
    final pager = await RollbackJournalPager.open(
        ModelFile(wideBase, probe), ModelFile(Uint8List(0), probe));
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    await db.execute('UPDATE t SET v=?', ['b' * 7000]);
    final operations = probe.operations;
    await db.close();
    expect(operations, greaterThan(0));
    final faults = CrashController()..crashAt = 1;
    final file = ModelFile(wideBase, faults);
    final log = ModelFile(Uint8List(0), faults);
    final crashing = await RollbackJournalPager.open(file, log);
    final writer = await MutableSqliteDatabase.fromJournalPager(crashing);
    await expectLater(writer.execute('UPDATE t SET v=?', ['b' * 7000]),
        throwsA(isA<SimulatedCrash>()));
    file.crash();
    log.crash();
    faults.crashAt = null;
    final recovered = await RollbackJournalPager.open(file, log);
    expect(await recovered.readImage(), wideBase);
    await recovered.close();
    await writer.close();

    final walFaults = CrashController();
    final walFile = ModelFile(
        File('test/fixtures/wal-base.db').readAsBytesSync(), walFaults);
    final walLog = ModelFile(Uint8List(0), walFaults);
    final wal = await WalPager.open(walFile, walLog,
        exclusiveOwnership: true, walIndexAbsent: true);
    final walDb = await MutableSqliteDatabase.fromJournalPager(wal);
    await walDb.execute('CREATE TABLE plain(v)');
    await walDb.execute("INSERT INTO plain VALUES('a')");
    final committed = await wal.readImage();
    await walDb.close();
    final nextFaults = CrashController()..persistUnsynced = true;
    final nextFile = ModelFile(walFile.durable, nextFaults);
    final nextLog = ModelFile(walLog.durable, nextFaults);
    final next = await WalPager.open(nextFile, nextLog,
        exclusiveOwnership: true, walIndexAbsent: true);
    final nextDb = await MutableSqliteDatabase.fromJournalPager(next);
    await nextDb.execute("INSERT INTO plain VALUES('b')");
    final walOperations = nextFaults.operations;
    await nextDb.close();
    final crashFaults = CrashController()
      ..persistUnsynced = true
      ..crashAt = walOperations ~/ 2;
    final crashFile = ModelFile(walFile.durable, crashFaults);
    final crashLog = ModelFile(walLog.durable, crashFaults);
    final crashPager = await WalPager.open(crashFile, crashLog,
        exclusiveOwnership: true, walIndexAbsent: true);
    final crashDb = await MutableSqliteDatabase.fromJournalPager(crashPager);
    await expectLater(crashDb.execute("INSERT INTO plain VALUES('b')"),
        throwsA(isA<SimulatedCrash>()));
    crashFile.crash();
    crashLog.crash();
    crashFaults.crashAt = null;
    final restored = await WalPager.open(crashFile, crashLog,
        exclusiveOwnership: true, walIndexAbsent: true);
    final image = await restored.readImage();
    expect(image, committed);
    final check = await MutableSqliteDatabase.fromImage(image);
    expect((await check.query('SELECT v FROM plain')).rows, [
      ['a']
    ]);
    expect(
        (await check.query('PRAGMA integrity_check')).rows.single.single, 'ok');
    await check.close();
    await restored.close();
    await crashDb.close();
  });

  test('the AOT page-write sample records this revision only', () {
    final document = jsonDecode(
        File('../../benchmark_results/page_writes_linux_x64.json')
            .readAsStringSync()) as Map<String, Object?>;
    expect(document['runtime'], 'AOT executable');
    expect(document['os'], 'linux');
    expect(document['workload'], contains('not a before/after delta'));
    expect(document['limitations'], contains('No earlier sample exists'));
    final timings = document['microseconds'] as Map<String, Object?>;
    for (final key in [
      'batch_insert_10000',
      'batch_insert_100000',
      'single_row_inserts_200'
    ]) {
      expect(timings.containsKey(key), isTrue, reason: key);
    }
    expect((timings['batch_insert_10000'] as List).length, 3);
    expect((timings['batch_insert_100000'] as List).length, 1);
    expect(timings['single_row_inserts_200'], isA<int>());
  });

  test('separate NOT NULL edits commit through changed pages', () async {
    const create = '''
CREATE TABLE bench (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  body TEXT NOT NULL,
  n INTEGER NOT NULL
)
''';
    final controller = CrashController();
    final databaseFile = ModelFile(await _emptyImage(), controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(databaseFile, journal);
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    addTearDown(db.close);
    await db.execute(create);
    for (var id = 1; id <= 200; id++) {
      final result = await db.execute(
          'INSERT INTO bench(id, name, body, n) VALUES (?, ?, ?, ?)',
          [id, 'n$id', 'b$id', id]);
      expect(result.changes, 1);
    }
    final pageSize = DatabaseHeader.decode(databaseFile.volatile).pageSize;
    expect(journal.volatile.length,
        lessThan(RollbackJournalPager.checkpointBytes + pageSize * 8));
    for (var id = 1; id <= 200; id++) {
      expect(
          (await db.execute('UPDATE bench SET n = n + 1 WHERE id = ?', [id]))
              .changes,
          1);
    }
    expect(journal.volatile.length,
        lessThan(RollbackJournalPager.checkpointBytes + pageSize * 8));
    final sum = 200 * 201 ~/ 2 + 200;
    expect(
        (await db.query('SELECT COUNT(*), COALESCE(SUM(n), 0) FROM bench'))
            .rows
            .single,
        [BigInt.from(200), BigInt.from(sum)]);
    for (var id = 1; id <= 200; id++) {
      expect((await db.execute('DELETE FROM bench WHERE id = ?', [id])).changes,
          1);
    }
    expect((await db.query('SELECT COUNT(*) FROM bench')).rows.single.single,
        BigInt.zero);
    await db.close();
    final image = Uint8List.fromList(databaseFile.durable);
    final opened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(opened.close);
    expect(
        (await opened.query('SELECT COUNT(*) FROM bench')).rows.single.single,
        BigInt.zero);
    expect((await opened.query('PRAGMA integrity_check')).rows.single.single,
        'ok');
    expect(
        (await opened.execute('UPDATE bench SET n = n + 1 WHERE id = ?', [1]))
            .changes,
        0);
    expect(
        (await opened.execute('DELETE FROM bench WHERE id = ?', [1])).changes,
        0);
  });

  test('a reopened file keeps separate inserts, updates, and deletes',
      () async {
    const create = '''
CREATE TABLE bench (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  body TEXT NOT NULL,
  n INTEGER NOT NULL
)
''';
    final controller = CrashController();
    final databaseFile = ModelFile(await _emptyImage(), controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(databaseFile, journal);
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    addTearDown(db.close);
    await db.execute(create);
    for (var id = 1; id <= 200; id++) {
      await db.execute(
          'INSERT INTO bench(id, name, body, n) VALUES (?, ?, ?, ?)',
          [id, 'n$id', 'b$id', id]);
    }
    for (var id = 1; id <= 200; id++) {
      await db.execute('UPDATE bench SET n = n + 1 WHERE id = ?', [id]);
    }
    await db.execute('DELETE FROM bench WHERE id = ?', [7]);
    await db.execute('UPDATE bench SET n = n + 1');
    await db.close();
    final image = Uint8List.fromList(databaseFile.durable);
    final opened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(opened.close);
    expect((await opened.query('PRAGMA integrity_check')).rows.single.single,
        'ok');
    final rows =
        await opened.query('SELECT COUNT(*), COALESCE(SUM(n), 0) FROM bench');
    final expectedSum = (200 * 201 ~/ 2 + 200 * 2) - (7 + 2);
    expect(rows.rows.single, [BigInt.from(199), BigInt.from(expectedSum)]);
    final point =
        await opened.query('SELECT body FROM bench WHERE id = ?', [8]);
    expect(point.rows.single.single, 'b8');
    expect(
        (await opened.query('SELECT body FROM bench WHERE id = ?', [7])).rows,
        isEmpty);
  });

  test('a file addend stays in the redo until restart or close', () async {
    const create = '''
CREATE TABLE bench (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  body TEXT NOT NULL,
  n INTEGER NOT NULL
)
''';
    final controller = CrashController();
    final databaseFile = ModelFile(await _emptyImage(), controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(databaseFile, journal);
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    addTearDown(db.close);
    await db.execute(create);
    await db.execute('INSERT INTO bench(id, name, body, n) VALUES (1, ?, ?, ?)',
        ['n1', 'b1', 1]);
    await db.execute('INSERT INTO bench(id, name, body, n) VALUES (2, ?, ?, ?)',
        ['n2', 'b2', 2]);
    final stale = Uint8List.fromList(databaseFile.volatile);
    final beforeJournal = journal.volatile.length;
    await db.execute('UPDATE bench SET n = n + 1');
    await db.execute('UPDATE bench SET n = n + 1');
    expect(databaseFile.volatile, stale);
    expect(journal.volatile.length, greaterThan(beforeJournal));
    await db.execute('DELETE FROM bench WHERE id = ?', [1]);
    await db.execute('INSERT INTO bench(id, name, body, n) VALUES (3, ?, ?, ?)',
        ['n3', 'b3', 3]);
    expect(
        (await db.query('SELECT COALESCE(SUM(n), 0) FROM bench')).rows.single,
        [BigInt.from((2 + 2) + 3)]);
    final persisted = Uint8List.fromList(databaseFile.durable);
    final persistedJournal = Uint8List.fromList(journal.durable);
    final reopenedPager = await RollbackJournalPager.open(
      ModelFile(persisted, CrashController()),
      ModelFile(persistedJournal, CrashController()),
    );
    final reopened =
        await MutableSqliteDatabase.fromJournalPager(reopenedPager);
    addTearDown(reopened.close);
    expect(
        (await reopened.query(
                'SELECT COUNT(*), COALESCE(SUM(n), 0) FROM bench ORDER BY id'))
            .rows
            .single,
        [BigInt.two, BigInt.from(7)]);
    expect(
        (await reopened.query('SELECT n FROM bench WHERE id = 2'))
            .rows
            .single
            .single,
        BigInt.from(4));
    expect((await reopened.query('PRAGMA integrity_check')).rows.single.single,
        'ok');
    await db.close();
    final closed = await MutableSqliteDatabase.fromImage(databaseFile.durable);
    addTearDown(closed.close);
    expect(
        (await closed.query('SELECT COUNT(*), COALESCE(SUM(n), 0) FROM bench'))
            .rows
            .single,
        [BigInt.two, BigInt.from(7)]);
  });

  test('a file addend is dropped when the redo sync does not finish', () async {
    const create = '''
CREATE TABLE bench (
  id INTEGER PRIMARY KEY,
  n INTEGER NOT NULL
)
''';
    Future<void> crash(int step, List<Object?> expected) async {
      final faults = CrashController();
      final file = ModelFile(await _emptyImage(), faults);
      final log = ModelFile(Uint8List(0), faults);
      final pager = await RollbackJournalPager.open(file, log);
      final db = await MutableSqliteDatabase.fromJournalPager(pager);
      addTearDown(db.close);
      await db.execute(create);
      await db.execute('INSERT INTO bench(id, n) VALUES (1, 4)');
      faults.crashAt = faults.operations + step;
      await expectLater(db.execute('UPDATE bench SET n = n + 1'),
          throwsA(isA<SimulatedCrash>()));
      file.crash();
      log.crash();
      faults.crashAt = null;
      final recovered = await RollbackJournalPager.open(file, log);
      final opened = await MutableSqliteDatabase.fromJournalPager(recovered);
      addTearDown(opened.close);
      expect((await opened.query('SELECT n FROM bench')).rows.single, expected);
    }

    await crash(1, [BigInt.from(4)]);
    await crash(2, [BigInt.from(5)]);
  });
}

Future<Uint8List> _emptyImage() async {
  final created = await MutableSqliteDatabase.create();
  final image = created.exportImage();
  await created.close();
  return image;
}

Future<Map<int, List<int>>> _indexPages(Uint8List image, String table) async {
  final pager = await ReadOnlyPager.open(ByteImageStorage(image));
  try {
    final catalog = await DatabaseCatalog.read(pager);
    final pages = <int, List<int>>{};
    for (final entry in catalog.entries.where((entry) =>
        entry.type == 'index' &&
        entry.tableName.toLowerCase() == table.toLowerCase() &&
        entry.rootPage > 1)) {
      pages[entry.rootPage] = [
        ...(await pager.readPage(entry.rootPage)),
      ];
    }
    return pages;
  } finally {
    await pager.close();
  }
}
