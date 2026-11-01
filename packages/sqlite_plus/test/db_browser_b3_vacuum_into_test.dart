import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/src/sql/vacuum_into_crash.dart';
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
  late Directory dir;

  setUpAll(() async {
    tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sqlite-plus-vacuum-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  String pinMessage(ProcessResult result) {
    final text = result.stderr.toString().trim();
    final line = text.split('\n').firstWhere(
        (row) => row.startsWith('Error') || row.startsWith('Parse error'),
        orElse: () => text);
    const marker = 'argument: ';
    final index = line.indexOf(marker);
    if (index >= 0) return line.substring(index + marker.length).trim();
    final generic = line.indexOf(': ');
    return generic < 0 ? line : line.substring(generic + 2).trim();
  }

  Future<String> pinText(String database, String sql) async {
    final result = await Process.run(tool, [database, sql]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return result.stdout.toString().trim();
  }

  Future<void> expectSameError(MutableSqliteDatabase db, String sql) async {
    final pin = await Process.run(tool, [':memory:', sql]);
    expect(pin.exitCode, isNonZero, reason: sql);
    await expectLater(
        db.execute(sql),
        throwsA(isA<SqlException>()
            .having((error) => error.message, 'message', pinMessage(pin))));
  }

  test('VACUUM INTO matches the pinned file, errors, and a crash', () async {
    final out = '${dir.path}/out.db';
    final script = "CREATE TABLE t(v); INSERT INTO t VALUES (1),(3); "
        "VACUUM INTO '$out'; SELECT v FROM t;";
    expect(await pinText(':memory:', script), '1\n3');
    expect(await pinText(out, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n1\n3');
    final again = await Process.run(tool, [':memory:', "VACUUM INTO '$out';"]);
    expect(again.exitCode, isNonZero);
    expect(pinMessage(again), 'output file already exists');

    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute('INSERT INTO t VALUES (1),(3)');
    final before = db.exportImage();
    final dest = '${dir.path}/engine.db';
    expect((await db.execute("VACUUM INTO '$dest'")).changes, 0);
    expect(db.exportImage(), before);
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
    expect(await pinText(dest, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n1\n3');
    await expectSameError(db, "VACUUM INTO '$dest'");
    expect(File(dest).existsSync(), isTrue);

    final txnPath = '${dir.path}/txn.db';
    final txn = await Process.run(tool,
        [':memory:', "BEGIN; CREATE TABLE t(v); VACUUM INTO '$txnPath';"]);
    expect(pinMessage(txn), 'cannot VACUUM from within a transaction');
    final plainTxn = await Process.run(
        tool, [':memory:', 'BEGIN; CREATE TABLE t(v); VACUUM;']);
    expect(pinMessage(plainTxn), 'cannot VACUUM from within a transaction');
    await db.execute('BEGIN');
    await expectLater(
        db.execute("VACUUM INTO '$txnPath'"),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'cannot VACUUM from within a transaction')));
    expect(File(txnPath).existsSync(), isFalse);
    await expectLater(
        db.execute('VACUUM'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'cannot VACUUM from within a transaction')));
    expect(db.inTransaction, isTrue);
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);

    final named = '${dir.path}/main.db';
    expect(
        await pinText(':memory:',
            "CREATE TABLE t(v); INSERT INTO t VALUES (4); VACUUM main INTO '$named'; SELECT v FROM t;"),
        '4');
    expect(await pinText(named, 'SELECT v FROM t;'), '4');
    final engineNamed = '${dir.path}/engine-main.db';
    expect((await db.execute("VACUUM main INTO '$engineNamed'")).changes, 0);
    expect(
        await pinText(engineNamed, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n1\n3');

    final joined = '${dir.path}/joined.db';
    final expr = "VACUUM INTO ('${dir.path}/' || 'joined.db')";
    expect(
        await pinText(
            ':memory:', 'CREATE TABLE t(v); INSERT INTO t VALUES (8); $expr;'),
        isEmpty);
    expect(await pinText(joined, 'SELECT v FROM t;'), '8');
    final engineJoined = '${dir.path}/engine-joined.db';
    expect(
        (await db.execute("VACUUM INTO ('${dir.path}/' || 'engine-joined.db')"))
            .changes,
        0);
    expect(
        await pinText(engineJoined, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n1\n3');

    for (final sql in [
      'VACUUM INTO NULL',
      'VACUUM INTO 1',
      "VACUUM INTO x'61'",
      'VACUUM INTO ?'
    ]) {
      final fresh = await MutableSqliteDatabase.create();
      addTearDown(fresh.close);
      await expectSameError(fresh, sql);
    }
    final missing = '${dir.path}/missing/a.db';
    await expectSameError(db, "VACUUM INTO '$missing'");
    expect(File(missing).existsSync(), isFalse);
    final folder = Directory('${dir.path}/folder');
    await folder.create();
    await expectSameError(db, "VACUUM INTO '${folder.path}'");
    expect(db.exportImage(), before);

    expect(
        (await db.execute("VACUUM INTO ?", ['${dir.path}/bound.db'])).changes,
        0);
    expect(
        await pinText(
            '${dir.path}/bound.db', 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n1\n3');

    final emptyFile = File('${dir.path}/empty.db');
    await emptyFile.writeAsBytes(const []);
    expect(
        await pinText(':memory:',
            "CREATE TABLE t(v); INSERT INTO t VALUES (7); VACUUM INTO '${emptyFile.path}';"),
        isEmpty);
    expect(await pinText(emptyFile.path, 'SELECT v FROM t;'), '7');
    final engineEmpty = File('${dir.path}/engine-empty.db');
    await engineEmpty.writeAsBytes(const []);
    await db.execute("VACUUM INTO '${engineEmpty.path}'");
    expect(
        await pinText(
            engineEmpty.path, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n1\n3');
    expect(await pinText(':memory:', "VACUUM INTO ''; SELECT 1;"), '1');
    expect((await db.execute("VACUUM INTO ''")).changes, 0);
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);

    await db.execute('DELETE FROM t WHERE v=1');
    final withFreelist = db.exportImage();
    final freed = '${dir.path}/freed.db';
    expect(
        await pinText(':memory:',
            "CREATE TABLE t(v); INSERT INTO t VALUES (1),(3); DELETE FROM t WHERE v=1; VACUUM INTO '$freed'; SELECT v FROM t;"),
        '3');
    expect(await pinText(freed, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n3');
    final engineFreed = '${dir.path}/engine-freed.db';
    await db.execute("VACUUM INTO '$engineFreed'");
    expect(db.exportImage(), withFreelist);
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.from(3)]
    ]);
    expect(
        await pinText(engineFreed, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n3');

    final crashDest = '${dir.path}/crash.db';
    db.crashVacuumIntoBeforeRename = true;
    await expectLater(db.execute("VACUUM INTO '$crashDest'"),
        throwsA(isA<VacuumIntoCrash>()));
    expect(File(crashDest).existsSync(), isFalse);
    final temp = File('$crashDest-vacuuminto');
    expect(temp.existsSync(), isTrue);
    expect(await pinText(temp.path, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n3');
    expect((await db.query('SELECT v FROM t')).rows, [
      [BigInt.from(3)]
    ]);
    db.crashVacuumIntoBeforeRename = false;
    await db.execute("VACUUM INTO '$crashDest'");
    expect(File(crashDest).existsSync(), isTrue);
    expect(temp.existsSync(), isFalse);
    expect(await pinText(crashDest, 'PRAGMA integrity_check; SELECT v FROM t;'),
        'ok\n3');
    expect(db.exportImage(), withFreelist);

    await db.execute('INSERT INTO t VALUES (1)');
    await db.execute('VACUUM');
    expect((await db.query('SELECT v FROM t ORDER BY v')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    expect(
        await pinText(':memory:',
            "CREATE TABLE t(v); INSERT INTO t VALUES (1),(3); DELETE FROM t WHERE v=1; INSERT INTO t VALUES (1); VACUUM; SELECT v FROM t ORDER BY v;"),
        '1\n3');

    final tempOut = '${dir.path}/temp.db';
    final tempDb = await MutableSqliteDatabase.create();
    addTearDown(tempDb.close);
    await tempDb.execute('CREATE TEMP TABLE t(v)');
    await tempDb.execute('INSERT INTO t VALUES (5)');
    expect((await tempDb.execute("VACUUM temp INTO '$tempOut'")).changes, 0);
    expect(File(tempOut).existsSync(), isFalse);
    expect((await tempDb.query('SELECT v FROM t')).rows, [
      [BigInt.from(5)]
    ]);
    expect((await tempDb.execute('VACUUM temp')).changes, 0);
    expect((await tempDb.execute('VACUUM TEMP INTO NULL')).changes, 0);
    await tempDb.execute('BEGIN');
    expect((await tempDb.execute('VACUUM temp')).changes, 0);
    await tempDb.execute('COMMIT');
    expect(
        await pinText(':memory:',
            "CREATE TEMP TABLE t(v); INSERT INTO t VALUES (5); VACUUM temp INTO '${dir.path}/pin-temp.db'; SELECT v FROM temp.t;"),
        '5');
    expect(File('${dir.path}/pin-temp.db').existsSync(), isFalse);
    expect(
        await pinText(
            ':memory:', 'BEGIN; VACUUM temp INTO NULL; COMMIT; SELECT 1;'),
        '1');

    final auxOut = '${dir.path}/aux.db';
    await db.execute("ATTACH ':memory:' AS aux");
    await db.execute('CREATE TABLE aux.u(v)');
    await db.execute("INSERT INTO aux.u VALUES ('m')");
    await db.execute("VACUUM aux INTO '$auxOut'");
    expect(await pinText(auxOut, 'PRAGMA integrity_check; SELECT v FROM u;'),
        'ok\nm');
    expect((await db.query('SELECT v FROM aux.u')).rows, [
      ['m']
    ]);
    expect((await db.query('SELECT v FROM t ORDER BY v')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
  });
}
