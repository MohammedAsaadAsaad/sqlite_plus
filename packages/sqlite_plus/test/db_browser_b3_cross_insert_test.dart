import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
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

  late Directory directory;
  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('sqlite-plus-cross-');
  });
  tearDownAll(() {
    directory.deleteSync(recursive: true);
  });

  test('cross-database insert rows match the pinned CLI, including reopen',
      () async {
    final tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);

    const memory = "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
        "ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v); "
        "INSERT INTO aux.u SELECT v FROM t; "
        "SELECT count(*) FROM aux.u; SELECT v FROM aux.u; SELECT v FROM t;";
    expect(await _engine(memory), await _pinned(tool, ':memory:', memory));

    const empty = "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
        "ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v); "
        "INSERT INTO aux.u SELECT v FROM t WHERE 0; "
        "SELECT count(*) FROM aux.u;";
    expect(await _engine(empty), await _pinned(tool, ':memory:', empty));

    const several =
        "CREATE TABLE t(v); INSERT INTO t VALUES ('m'), (''), (NULL); "
        "ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v); "
        "INSERT INTO aux.u SELECT v FROM t; "
        "SELECT v FROM aux.u ORDER BY v; SELECT v FROM t ORDER BY v;";
    expect(await _engine(several), await _pinned(tool, ':memory:', several));

    const otherWay = "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
        "ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v); "
        "INSERT INTO aux.u VALUES ('from-aux'); "
        "INSERT INTO t SELECT v FROM aux.u; "
        "SELECT v FROM t ORDER BY v;";
    expect(await _engine(otherWay), await _pinned(tool, ':memory:', otherWay));

    const rolled = "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
        "ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v); "
        "BEGIN; INSERT INTO aux.u SELECT v FROM t; ROLLBACK; "
        "SELECT count(*) FROM aux.u; SELECT v FROM t;";
    expect(await _engine(rolled), await _pinned(tool, ':memory:', rolled));

    final missing = await Process.run(tool, [
      ':memory:',
      "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
          "INSERT INTO aux.u SELECT v FROM t;"
    ]);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such table: aux.u'));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute("INSERT INTO t VALUES ('m')");
    await expectLater(db.execute('INSERT INTO aux.u SELECT v FROM t'),
        throwsA(isA<SqlException>()));
    expect((await db.query('SELECT v FROM t')).rows, [
      ['m']
    ]);

    final pinMain = '${directory.path}/pin-main.db';
    final pinAux = '${directory.path}/pin-aux.db';
    final pinScript = "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); "
        "ATTACH '$pinAux' AS aux; CREATE TABLE aux.u(v); "
        "INSERT INTO aux.u SELECT v FROM t;";
    final pinned = await Process.run(tool, [pinMain, pinScript]);
    expect(pinned.exitCode, 0, reason: pinned.stderr.toString());
    final pinReopen = await Process.run(tool, [
      pinMain,
      "ATTACH '$pinAux' AS aux; SELECT count(*) FROM aux.u; "
          "SELECT v FROM aux.u; SELECT v FROM t;"
    ]);
    expect(pinReopen.exitCode, 0, reason: pinReopen.stderr.toString());
    expect(pinReopen.stdout.toString().trim(), '1\nm\nm');

    final image = (await MutableSqliteDatabase.create()).exportImage();
    final engineMain = '${directory.path}/engine-main.db';
    final engineAux = '${directory.path}/engine-aux.db';
    final mainLog = '$engineMain-journal';
    final auxLog = '$engineAux-journal';
    final commitLog = '${directory.path}/schema-commit';
    await File(engineMain).writeAsBytes(image);
    await File(engineAux).writeAsBytes(image);
    await File(mainLog).writeAsBytes(const <int>[]);
    await File(auxLog).writeAsBytes(const <int>[]);
    await File(commitLog).writeAsBytes(const <int>[]);
    final database = await DurableFileStorageBackend.openExisting(engineMain,
        directoryEntryIsDurable: true);
    final journal = await DurableFileStorageBackend.openExisting(mainLog,
        directoryEntryIsDurable: true);
    final pager = await RollbackJournalPager.open(database, journal);
    final fileDb = await MutableSqliteDatabase.fromJournalPager(pager);
    fileDb.schemaCommitJournal = await DurableFileStorageBackend.openExisting(
        commitLog,
        directoryEntryIsDurable: true);
    fileDb.openAttachedPager = (path) async {
      final file = await DurableFileStorageBackend.openExisting(path,
          directoryEntryIsDurable: true);
      final redo = await DurableFileStorageBackend.openExisting('$path-journal',
          directoryEntryIsDurable: true);
      return RollbackJournalPager.open(file, redo);
    };
    await fileDb.execute('CREATE TABLE t(v)');
    await fileDb.execute("INSERT INTO t VALUES ('m')");
    await fileDb.execute("ATTACH '$engineAux' AS aux");
    await fileDb.execute('CREATE TABLE aux.u(v)');
    expect((await fileDb.query('INSERT INTO aux.u SELECT v FROM t')).rows,
        isEmpty);
    expect((await fileDb.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.one]
    ]);
    expect((await fileDb.query('SELECT v FROM aux.u')).rows, [
      ['m']
    ]);
    expect((await fileDb.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
    await fileDb.close();

    final engineReopen = await Process.run(tool, [
      engineMain,
      "ATTACH '$engineAux' AS aux; SELECT count(*) FROM aux.u; "
          "SELECT v FROM aux.u; SELECT v FROM t; PRAGMA integrity_check;"
    ]);
    expect(engineReopen.exitCode, 0, reason: engineReopen.stderr.toString());
    expect(engineReopen.stdout.toString().trim(), '1\nm\nm\nok');

    final mainAgain = await DurableFileStorageBackend.openExisting(engineMain,
        directoryEntryIsDurable: true);
    final mainLogAgain = await DurableFileStorageBackend.openExisting(mainLog,
        directoryEntryIsDurable: true);
    final auxAgain = await DurableFileStorageBackend.openExisting(engineAux,
        directoryEntryIsDurable: true);
    final auxLogAgain = await DurableFileStorageBackend.openExisting(auxLog,
        directoryEntryIsDurable: true);
    final mainPager = await RollbackJournalPager.open(mainAgain, mainLogAgain);
    final auxPager = await RollbackJournalPager.open(auxAgain, auxLogAgain);
    final reopenedMain =
        await MutableSqliteDatabase.fromJournalPager(mainPager);
    final reopenedAux = await MutableSqliteDatabase.fromJournalPager(auxPager);
    expect((await reopenedMain.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
    expect((await reopenedAux.query('SELECT count(*) FROM u')).rows, [
      [BigInt.one]
    ]);
    expect((await reopenedAux.query('SELECT v FROM u')).rows, [
      ['m']
    ]);
    expect((await reopenedMain.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    expect((await reopenedAux.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    await reopenedMain.close();
    await reopenedAux.close();
  });
}

Future<String> _pinned(String tool, String path, String sql) async {
  final result = await Process.run(tool, [path, sql]);
  if (result.exitCode != 0) {
    return 'ERR ${result.stderr.toString().trim()}';
  }
  return result.stdout.toString().trim();
}

Future<String> _engine(String sql) async {
  final db = await MutableSqliteDatabase.create();
  try {
    final parts = <String>[];
    for (final statement in _statements(sql)) {
      final keyword = statement.trimLeft().toUpperCase();
      if (keyword.startsWith('SELECT') || keyword.startsWith('PRAGMA')) {
        final rows = await db.query(statement);
        parts.add(rows.rows
            .map((row) => row.map((value) => value ?? '').join('|'))
            .join('\n'));
      } else {
        final returned = (await db.execute(statement)).returning;
        if (returned != null && returned.rows.isNotEmpty) {
          parts.add(returned.rows
              .map((row) => row.map((value) => value ?? '').join('|'))
              .join('\n'));
        }
      }
    }
    return parts.join('\n').trim();
  } on SqlException catch (error) {
    return 'ERR ${error.message}';
  } finally {
    await db.close();
  }
}

List<String> _statements(String sql) {
  final statements = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote.isNotEmpty) {
      buffer.write(char);
      if (char == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          buffer.write(sql[++i]);
        } else {
          quote = '';
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      buffer.write(char);
      continue;
    }
    if (char == ';') {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) statements.add(text);
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  final text = buffer.toString().trim();
  if (text.isNotEmpty) statements.add(text);
  return statements;
}
