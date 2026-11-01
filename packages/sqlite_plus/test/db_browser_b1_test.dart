import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus/src/btree/database_image_builder.dart';
import 'package:sqlite_plus/src/format/hot_journal.dart';
import 'package:sqlite_plus/src/format/pointer_map.dart';
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

  test('a non-vacuum read does not fetch a pointer-map page', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute("INSERT INTO t VALUES('a')");
    final image = db.exportImage();
    final reader = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
    addTearDown(reader.close);
    expect(reader.pagesRead, 1);
    expect((await reader.query('SELECT v FROM t')).rows, [
      ['a']
    ]);
    // Schema page at open, then the same page again for the scan.
    expect(reader.pagesRead, 2);
    expect((await reader.query('PRAGMA auto_vacuum')).rows.single.single,
        BigInt.zero);
  });

  test('sqlite_stat4 samples do not change the stat1 plan or its page reads',
      () async {
    Future<Uint8List> image(bool stat4) {
      return Future.value(
          DatabaseImageBuilder.build(DatabaseImageBuilder.empty(), [
        ImageObject('table', 'small', 'small', 'CREATE TABLE small(v)',
            tableRows: [
              TableRow(BigInt.one, ['s'])
            ]),
        ImageObject('table', 'big', 'big', 'CREATE TABLE big(v)', tableRows: [
          for (var i = 0; i < 40; i++)
            TableRow(BigInt.from(i + 1), [i.toString().padLeft(4, '0')])
        ]),
        ImageObject('table', 'sqlite_stat1', 'sqlite_stat1',
            'CREATE TABLE sqlite_stat1(tbl,idx,stat)',
            tableRows: [
              TableRow(BigInt.one, ['small', null, '1']),
              TableRow(BigInt.two, ['big', null, '40'])
            ]),
        if (stat4)
          ImageObject('table', 'sqlite_stat4', 'sqlite_stat4',
              'CREATE TABLE sqlite_stat4(tbl,idx,neq,nlt,ndlt,sample)',
              tableRows: [
                TableRow(BigInt.one, ['big', null, '1', '1', '1', null]),
                TableRow(BigInt.two, ['small', null, '999', '999', '999', null])
              ])
      ]));
    }

    Future<int> reads(Uint8List bytes) async {
      final db = await SqliteDatabase.openReadOnly(ByteImageStorage(bytes));
      addTearDown(db.close);
      final plan = db.describeQueryPlan(
          'SELECT big.v, small.v FROM big, small ORDER BY big.v');
      expect(plan.first, contains('small'));
      expect(plan.last, contains('big'));
      final before = db.pagesRead;
      expect(
          (await db.query(
                  'SELECT big.v, small.v FROM big, small ORDER BY big.v LIMIT 1'))
              .rows,
          [
            ['0000', 's']
          ]);
      return db.pagesRead - before;
    }

    final without = await reads(await image(false));
    final withStat4 = await reads(await image(true));
    expect(withStat4, without);
  });

  test('official auto_vacuum and stat4 images match the pinned CLI', () async {
    final tool = await pinnedCli();
    if (tool == null) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final directory = Directory.systemTemp.createTempSync('sqlite-plus-b1-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final vacuum = '${directory.path}/vacuum.db';
    final created = await Process.run(tool, [
      vacuum,
      "PRAGMA auto_vacuum=FULL;"
          "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);"
          "INSERT INTO t(v) VALUES('one'),('two');"
          "CREATE INDEX t_v ON t(v);"
          "INSERT INTO t(v) SELECT hex(randomblob(80)) FROM generate_series(1,30);"
    ]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final bytes = await File(vacuum).readAsBytes();
    final header = DatabaseHeader.decode(bytes);
    expect(header.autoVacuumMode, 1);
    expect(header.pageSize, greaterThan(0));
    expect(PointerMap.isPage(header, 2), isTrue);
    final pager = await ReadOnlyPager.open(ByteImageStorage(bytes));
    addTearDown(pager.close);
    final map = await pager.readPage(2);
    expect(() => BtreePageHeader.decode(map, database: header, pageNumber: 2),
        throwsFormatException);
    final schema = await BtreeReader(pager).scanTable(1).toList();
    final tableRoot =
        schema.firstWhere((row) => row.values[1] == 't').values[3] as BigInt;
    final entry = PointerMap.entry(map, header, tableRoot.toInt());
    expect(entry.type, PointerMap.rootPage);
    final opened = await openReadOnlyFile(vacuum);
    addTearDown(opened.close);
    expect((await opened.query('PRAGMA auto_vacuum')).rows.single.single,
        BigInt.one);
    final engineRows = (await opened
            .query('SELECT id, v FROM t WHERE length(v) < 5 ORDER BY id'))
        .rows
        .map((row) => '${row[0]}|${row[1]}')
        .toList();
    expect(
        engineRows,
        await pinnedRows(tool, vacuum,
            "SELECT id, v FROM t WHERE length(v) < 5 ORDER BY id;"));
    expect(await File(vacuum).readAsBytes(), bytes);

    final stat4Cli = '/tmp/sqlite-build/sqlite3-stat4';
    final stat4 = '${directory.path}/stat4.db';
    if (File(stat4Cli).existsSync()) {
      final id = await Process.run(
          stat4Cli, [':memory:', 'SELECT sqlite_source_id();']);
      expect(id.stdout.toString().trim(), _pin);
      final analyzed = await Process.run(stat4Cli, [
        stat4,
        "PRAGMA auto_vacuum=NONE;"
            "CREATE TABLE small(v); CREATE TABLE big(v);"
            "INSERT INTO small VALUES('s');"
            "INSERT INTO big SELECT printf('%04d', value) FROM generate_series(0,39);"
            "ANALYZE;"
      ]);
      expect(analyzed.exitCode, 0, reason: analyzed.stderr.toString());
    } else {
      await File(stat4).writeAsBytes(
          DatabaseImageBuilder.build(DatabaseImageBuilder.empty(), [
        ImageObject('table', 'small', 'small', 'CREATE TABLE small(v)',
            tableRows: [
              TableRow(BigInt.one, ['s'])
            ]),
        ImageObject('table', 'sqlite_stat4', 'sqlite_stat4',
            'CREATE TABLE sqlite_stat4(tbl,idx,neq,nlt,ndlt,sample)',
            tableRows: [
              TableRow(BigInt.one, ['small', null, '1', '1', '1', null])
            ])
      ]));
    }
    final statDb = await openReadOnlyFile(stat4);
    addTearDown(statDb.close);
    final statRows = (await statDb.query('SELECT v FROM small'))
        .rows
        .map((row) => '${row.single}')
        .toList();
    expect(statRows, await pinnedRows(tool, stat4, 'SELECT v FROM small;'));
    final samples = (await statDb.query('SELECT count(*) FROM sqlite_stat4'))
        .rows
        .single
        .single;
    final cliCount =
        await pinnedRows(tool, stat4, 'SELECT count(*) FROM sqlite_stat4;');
    expect(samples.toString(), cliCount.single);
  });

  test('a pending WAL and a hot journal recover on the read path', () async {
    final tool = await pinnedCli();
    if (tool == null) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final directory =
        Directory.systemTemp.createTempSync('sqlite-plus-b1-log-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final wal = '${directory.path}/w.db';
    final script = await Process.run(tool, [
      wal,
      '.dbconfig no_ckpt_on_close on',
      'PRAGMA journal_mode=WAL;',
      'CREATE TABLE t(v);',
      "INSERT INTO t VALUES('pending');",
    ]);
    expect(script.exitCode, 0, reason: script.stderr.toString());
    expect(File('$wal-wal').existsSync(), isTrue);
    final walBytes = await File(wal).readAsBytes();
    final walLog = await File('$wal-wal').readAsBytes();
    final alone = '${directory.path}/alone.db';
    await File(alone).writeAsBytes(walBytes);
    final missing = await Process.run(tool, [alone, 'SELECT * FROM t;']);
    expect(missing.exitCode, isNot(0));
    final recovered = await openReadOnlyFile(wal);
    addTearDown(recovered.close);
    expect((await recovered.query('SELECT v FROM t')).rows, [
      ['pending']
    ]);
    expect((await recovered.query('PRAGMA journal_mode')).rows.single.single,
        'wal');
    expect(await File(wal).readAsBytes(), walBytes);
    expect(await File('$wal-wal').readAsBytes(), walLog);

    final journal = '${directory.path}/j.db';
    final beforeRun = await Process.run(tool, [
      journal,
      "PRAGMA auto_vacuum=NONE; CREATE TABLE t(v); INSERT INTO t VALUES('committed');"
    ]);
    expect(beforeRun.exitCode, 0, reason: beforeRun.stderr.toString());
    final before = await File(journal).readAsBytes();
    final afterRun = await Process.run(tool, [
      journal,
      "INSERT INTO t SELECT hex(randomblob(200)) FROM generate_series(1,30); INSERT INTO t VALUES('uncommitted');"
    ]);
    expect(afterRun.exitCode, 0, reason: afterRun.stderr.toString());
    final after = await File(journal).readAsBytes();
    const pageSize = 4096;
    final beforePages = before.length ~/ pageSize;
    final changed = <int>[
      for (var i = 0; i < beforePages; i++)
        if (!_samePage(before, after, i, pageSize)) i + 1
    ];
    expect(changed, isNotEmpty);
    final hot = _hotJournal(before, changed, beforePages, pageSize);
    await File(journal).writeAsBytes(after);
    await File('$journal-journal').writeAsBytes(hot);
    final restored = HotJournal.recover(after, hot);
    final copy = '${directory.path}/j-cli.db';
    await File(copy).writeAsBytes(after);
    await File('$copy-journal').writeAsBytes(hot);
    expect(await pinnedRows(tool, copy, 'SELECT v FROM t ORDER BY rowid;'),
        ['committed']);
    final engine = await openReadOnlyFile(journal);
    addTearDown(engine.close);
    expect((await engine.query('SELECT v FROM t ORDER BY rowid')).rows, [
      ['committed']
    ]);
    expect(restored.length, before.length);
    expect(await File(journal).readAsBytes(), after);
    expect(await File('$journal-journal').readAsBytes(), hot);

    final torn = Uint8List.sublistView(hot, 0, hot.length ~/ 2);
    final partial = HotJournal.recover(after, torn);
    expect(partial.length, lessThan(after.length));
    final ignored = HotJournal.recover(after, Uint8List(32));
    expect(ignored, after);

    final corrupt = Uint8List.fromList(hot);
    ByteData.sublistView(corrupt).setUint32(pageSize + 4 + pageSize, 0);
    final grownBad = HotJournal.recover(after, corrupt);
    expect(grownBad.length, before.length);
    final badFile = '${directory.path}/j-bad.db';
    await File(badFile).writeAsBytes(after);
    await File('$badFile-journal').writeAsBytes(corrupt);
    final cliBad =
        await Process.run(tool, [badFile, 'SELECT v FROM t ORDER BY rowid;']);
    expect(cliBad.exitCode, isNot(0));
    expect(cliBad.stderr.toString(), contains('malformed'));
    await expectLater(SqliteDatabase.openReadOnly(ByteImageStorage(grownBad)),
        throwsA(isA<FormatException>()));
    expect(await File(journal).readAsBytes(), after);

    final same = '${directory.path}/same.db';
    final sameCreated = await Process.run(tool, [
      same,
      "PRAGMA auto_vacuum=NONE; CREATE TABLE t(v); INSERT INTO t VALUES('committed');"
    ]);
    expect(sameCreated.exitCode, 0, reason: sameCreated.stderr.toString());
    final sameBefore = await File(same).readAsBytes();
    final sameUpdated =
        await Process.run(tool, [same, "UPDATE t SET v='changed';"]);
    expect(sameUpdated.exitCode, 0, reason: sameUpdated.stderr.toString());
    final sameAfter = await File(same).readAsBytes();
    expect(sameAfter.length, sameBefore.length);
    final samePages = [
      for (var i = 0; i < sameBefore.length ~/ pageSize; i++)
        if (!_samePage(sameBefore, sameAfter, i, pageSize)) i + 1
    ];
    final sameHot = _hotJournal(
        sameBefore, samePages, sameBefore.length ~/ pageSize, pageSize);
    final sameCorrupt = Uint8List.fromList(sameHot);
    ByteData.sublistView(sameCorrupt).setUint32(pageSize + 4 + pageSize, 0);
    final sameCopy = '${directory.path}/same-cli.db';
    await File(sameCopy).writeAsBytes(sameAfter);
    await File('$sameCopy-journal').writeAsBytes(sameCorrupt);
    expect(await pinnedRows(tool, sameCopy, 'SELECT v FROM t;'), ['changed']);
    final sameEngine = await SqliteDatabase.openReadOnly(
        ByteImageStorage(HotJournal.recover(sameAfter, sameCorrupt)));
    addTearDown(sameEngine.close);
    expect((await sameEngine.query('SELECT v FROM t')).rows, [
      ['changed']
    ]);
  });

  test('delete keeps a freelist and VACUUM shrinks, both like the pinned CLI',
      () async {
    final tool = await pinnedCli();
    if (tool == null) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    final values = [
      for (var i = 0; i < 200; i++) "('${i.toString().padLeft(24, '0')}')"
    ].join(',');
    await db.execute('INSERT INTO t(v) VALUES $values');
    final inserted = db.exportImage();
    await db.execute('DELETE FROM t');
    final deleted = db.exportImage();
    await db.execute('VACUUM');
    final vacuumed = db.exportImage();
    Future<List<String>> counts(Uint8List image) async {
      final directory =
          Directory.systemTemp.createTempSync('sqlite-plus-shrink-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/t.db';
      await File(path).writeAsBytes(image);
      return pinnedRows(tool, path,
          'SELECT page_count, freelist_count FROM pragma_page_count(), pragma_freelist_count(); PRAGMA integrity_check;');
    }

    expect(await counts(inserted), ['4|0', 'ok']);
    expect(await counts(deleted), ['4|2', 'ok']);
    expect(await counts(vacuumed), ['2|0', 'ok']);
    expect(vacuumed.length, lessThan(deleted.length));
  });

  test('a shared lock blocks another process and an exclusive lock blocks us',
      () async {
    final tool = await pinnedCli();
    if (tool == null) {
      markTestSkipped('pinned sqlite3 is not installed');
      return;
    }
    final directory = Directory.systemTemp.createTempSync('sqlite-plus-lock-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/t.db';
    final created = await Process.run(
        tool, [path, "CREATE TABLE t(v); INSERT INTO t VALUES('visible');"]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final ours = await openReadOnlyFile(path);
    addTearDown(ours.close);
    final blocked =
        await Process.run(tool, [path, 'BEGIN EXCLUSIVE; SELECT 1;']);
    expect(blocked.exitCode, isNot(0));
    expect(blocked.stderr.toString(), contains('locked'));
    final shared = await Process.run(tool, [path, 'SELECT v FROM t;']);
    expect(shared.exitCode, 0, reason: shared.stderr.toString());
    expect(shared.stdout.toString().trim(), 'visible');
    await ours.close();

    final walPath = '${directory.path}/w.db';
    final walScript = await Process.run(tool, [
      walPath,
      '.dbconfig no_ckpt_on_close on',
      'PRAGMA journal_mode=WAL;',
      'CREATE TABLE t(v);',
      "INSERT INTO t VALUES('pending');",
    ]);
    expect(walScript.exitCode, 0, reason: walScript.stderr.toString());
    final shmPath = '$walPath-shm';
    if (!File(shmPath).existsSync()) {
      await File(shmPath).writeAsBytes(Uint8List(0));
    }
    // Advisory locks are per process, so the holder has to be another process.
    final blockedWal = await _holdShmLocks(
        directory.path, shmPath, SqliteLock.walRead, SqliteLock.walReadCount);
    addTearDown(() => blockedWal.kill());
    await expectLater(openReadOnlyFile(walPath), throwsA(isA<SqlException>()));
    blockedWal.kill();
    await blockedWal.exitCode;
    final oneByte =
        await _holdShmLocks(directory.path, shmPath, SqliteLock.walRead, 1);
    addTearDown(() => oneByte.kill());
    final afterBlock = await openReadOnlyFile(walPath);
    addTearDown(afterBlock.close);
    expect((await afterBlock.query('SELECT v FROM t')).rows, [
      ['pending']
    ]);
    await afterBlock.close();
    oneByte.kill();

    final holder = await Process.start('stdbuf', ['-o0', '-e0', tool, path]);
    addTearDown(() => holder.kill());
    holder.stdin.writeln('BEGIN EXCLUSIVE;');
    holder.stdin.writeln('SELECT 7;');
    await holder.stdin.flush();
    final collected = StringBuffer();
    final errors = StringBuffer();
    holder.stdout.transform(utf8.decoder).listen(collected.write);
    holder.stderr.transform(utf8.decoder).listen(errors.write);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!collected.toString().contains('7')) {
      if (DateTime.now().isAfter(deadline)) {
        holder.kill();
        fail('exclusive holder did not start: $collected $errors');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await expectLater(openReadOnlyFile(path), throwsA(isA<SqlException>()));
    holder.kill();
  });
}

Future<Process> _holdShmLocks(
    String directory, String shmPath, int start, int count) async {
  final script = '$directory/hold_shm.py';
  await File(script).writeAsString('''
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
start = int(sys.argv[2])
count = int(sys.argv[3])
for i in range(count):
    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, start + i, os.SEEK_SET)
sys.stdout.write("ready\\n")
sys.stdout.flush()
sys.stdin.readline()
''');
  final process =
      await Process.start('python3', [script, shmPath, '$start', '$count']);
  final collected = StringBuffer();
  final errors = StringBuffer();
  process.stdout.transform(utf8.decoder).listen(collected.write);
  process.stderr.transform(utf8.decoder).listen(errors.write);
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!collected.toString().contains('ready')) {
    if (DateTime.now().isAfter(deadline)) {
      process.kill();
      fail('shm lock holder did not start: $collected $errors');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return process;
}

bool _samePage(Uint8List before, Uint8List after, int index, int pageSize) {
  final start = index * pageSize;
  for (var i = 0; i < pageSize; i++) {
    if (before[start + i] != after[start + i]) return false;
  }
  return true;
}

Uint8List _hotJournal(
    Uint8List before, List<int> pages, int originalPages, int pageSize) {
  const sector = 4096;
  const seed = 0x12345678;
  final header = Uint8List(sector);
  header.setRange(0, 8, const [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]);
  final fields = ByteData.sublistView(header);
  fields.setUint32(8, pages.length);
  fields.setUint32(12, seed);
  fields.setUint32(16, originalPages);
  fields.setUint32(20, sector);
  fields.setUint32(24, pageSize);
  final builder = BytesBuilder(copy: false)..add(header);
  for (final number in pages) {
    final page = Uint8List.sublistView(
        before, (number - 1) * pageSize, number * pageSize);
    final record = Uint8List(4 + pageSize + 4);
    final data = ByteData.sublistView(record);
    data.setUint32(0, number);
    record.setRange(4, 4 + pageSize, page);
    data.setUint32(4 + pageSize, _checksum(page, seed));
    builder.add(record);
  }
  return builder.takeBytes();
}

int _checksum(Uint8List page, int seed) {
  var sum = seed;
  var index = page.length - 200;
  while (index > 0) {
    sum = (sum + page[index]) & 0xffffffff;
    index -= 200;
  }
  return sum;
}
