import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'rollback_pager_test.dart'
    show CrashController, ModelFile, SimulatedCrash;

void main() {
  test('INSERT INTO aux.u SELECT v FROM t returns no row and keeps both',
      () async {
    final db = await _memory();
    expect((await db.query('INSERT INTO aux.u SELECT v FROM t')).rows, isEmpty);
    expect((await db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.one]
    ]);
    expect((await db.query('SELECT v FROM aux.u')).rows, [
      ['m']
    ]);
    expect((await db.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
    expect((await db.execute("INSERT INTO t VALUES ('n')")).changes, 1);
    expect((await db.query('SELECT v FROM t ORDER BY v')).rows, [
      ['m'],
      ['n']
    ]);
    expect(
        (await db.query(
                'SELECT main.t.v, aux.u.v FROM main.t, aux.u ORDER BY 1'))
            .rows,
        [
          ['m', 'm'],
          ['n', 'm']
        ]);
  });

  test('cross insert rejects a missing source, a missing target, and UPDATE',
      () async {
    final db = await _memory();
    await expectLater(db.execute('INSERT INTO aux.u SELECT v FROM missing'),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute('INSERT INTO aux.missing SELECT v FROM t'),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute('INSERT INTO nope.u SELECT v FROM t'),
        throwsA(isA<SqlException>()));
    await expectLater(
        db.execute('UPDATE aux.u SET v = (SELECT v FROM t)'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'cross-database statement is not supported')));
    await expectLater(
        db.execute('DELETE FROM aux.u WHERE v IN (SELECT v FROM t)'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'cross-database statement is not supported')));
    expect((await db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
  });

  test('empty, null, width, parameter, and reverse cross inserts', () async {
    final db = await _memory();
    expect(
        (await db.execute('INSERT INTO aux.u SELECT v FROM t WHERE 0')).changes,
        0);
    expect((await db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.zero]
    ]);
    await db.execute("INSERT INTO t VALUES (''), (NULL)");
    await db.execute(
        'INSERT INTO aux.u SELECT v FROM t WHERE v != ? OR v IS NULL', ['zz']);
    expect((await db.query('SELECT v FROM aux.u ORDER BY v')).rows, [
      [null],
      [''],
      ['m']
    ]);
    await db.execute('CREATE TABLE aux.wide(a, b)');
    await db.execute('CREATE TABLE pair(a, b)');
    await db.execute("INSERT INTO pair VALUES (1, 'm')");
    final returned = await db
        .query('INSERT INTO aux.wide SELECT a, b FROM pair RETURNING b');
    expect(returned.rows, [
      ['m']
    ]);
    expect((await db.query('SELECT a, b FROM aux.wide')).rows, [
      [BigInt.one, 'm']
    ]);
    await db.execute("INSERT INTO aux.u VALUES ('from-aux')");
    await db
        .execute('INSERT INTO t SELECT v FROM aux.u WHERE v = ?', ['from-aux']);
    expect((await db.query("SELECT v FROM t WHERE v = 'from-aux'")).rows, [
      ['from-aux']
    ]);
  });

  test('rollback and an unmodified DETACH leave the cross insert uncommitted',
      () async {
    final db = await _memory();
    await db.execute('BEGIN');
    await db.execute('INSERT INTO aux.u SELECT v FROM t');
    expect((await db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.one]
    ]);
    await expectLater(
        db.execute('DETACH aux'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'database aux is locked')));
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.zero]
    ]);
    expect((await db.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
    await db.execute('BEGIN');
    await db.execute('DETACH aux');
    await db.execute('ROLLBACK');
    await expectLater(
        db.query('SELECT * FROM aux.u'), throwsA(isA<SqlException>()));
  });

  test('a file commit of the cross insert reopens on both files', () async {
    final faults = CrashController();
    final opened = await _pair(faults);
    await opened.db.execute("ATTACH 'aux' AS aux");
    await opened.db.execute('CREATE TABLE t(v)');
    await opened.db.execute("INSERT INTO t VALUES ('m')");
    await opened.db.execute('CREATE TABLE aux.u(v)');
    expect(faults.operations, greaterThan(0));
    final before = faults.operations;
    expect((await opened.db.query('INSERT INTO aux.u SELECT v FROM t')).rows,
        isEmpty);
    expect(faults.operations, greaterThan(before));
    expect((await opened.db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.one]
    ]);
    expect((await opened.db.query("SELECT v FROM aux.u")).rows, [
      ['m']
    ]);
    await opened.db.close();
    final main = await MutableSqliteDatabase.fromImage(
        Uint8List.fromList(opened.mainFile.durable));
    final aux = await MutableSqliteDatabase.fromImage(
        Uint8List.fromList(opened.auxFile.durable));
    addTearDown(main.close);
    addTearDown(aux.close);
    expect((await main.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
    expect((await aux.query('SELECT count(*) FROM u')).rows, [
      [BigInt.one]
    ]);
    expect((await aux.query('SELECT v FROM u')).rows, [
      ['m']
    ]);
    expect((await main.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    expect((await aux.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('a transaction that writes both files needs the schema commit journal',
      () async {
    final faults = CrashController();
    final opened = await _pair(faults);
    await _seed(opened.db);
    opened.db.schemaCommitJournal = null;
    await opened.db.execute('BEGIN');
    await opened.db.execute("INSERT INTO t VALUES ('x')");
    await opened.db.execute('INSERT INTO aux.u SELECT v FROM t');
    await expectLater(
        opened.db.execute('COMMIT'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'durable commit across databases requires a schema commit journal')));
    await opened.db.execute('ROLLBACK');
    expect((await opened.db.query('SELECT v FROM t')).rows, [
      ['m']
    ]);
    expect((await opened.db.query('SELECT count(*) FROM aux.u')).rows, [
      [BigInt.zero]
    ]);
    await opened.db.close();
  });

  test('crash between the two schemas keeps both old or both new', () async {
    final setupFaults = CrashController();
    final setup = await _pair(setupFaults);
    await _seed(setup.db);
    await setup.db.close();
    final mainImage = Uint8List.fromList(setup.mainFile.durable);
    final auxImage = Uint8List.fromList(setup.auxFile.durable);
    final baselineFaults = CrashController();
    final baseline =
        await _pair(baselineFaults, mainImage: mainImage, auxImage: auxImage);
    await baseline.db.execute("ATTACH 'aux' AS aux");
    await baseline.db.execute('BEGIN');
    await baseline.db.execute("INSERT INTO t VALUES ('x')");
    await baseline.db.execute('INSERT INTO aux.u SELECT v FROM t');
    expect(baselineFaults.operations, 0);
    await baseline.db.execute('COMMIT');
    final operations = baselineFaults.operations;
    expect(operations, greaterThan(1));
    await baseline.db.close();
    expect(
        (await _rows(baseline.mainFile.durable, 'SELECT v FROM t ORDER BY v')),
        [
          ['m'],
          ['x']
        ]);
    expect(
        (await _rows(baseline.auxFile.durable, 'SELECT v FROM u ORDER BY v')), [
      ['m'],
      ['x']
    ]);

    for (final persistUnsynced in [false, true]) {
      var sawOld = false;
      var sawNew = false;
      for (var point = 1; point <= operations; point++) {
        final faults = CrashController()
          ..persistUnsynced = persistUnsynced
          ..crashAt = point;
        final opened =
            await _pair(faults, mainImage: mainImage, auxImage: auxImage);
        await opened.db.execute("ATTACH 'aux' AS aux");
        await opened.db.execute('BEGIN');
        await opened.db.execute("INSERT INTO t VALUES ('x')");
        await opened.db.execute('INSERT INTO aux.u SELECT v FROM t');
        await expectLater(
            opened.db.execute('COMMIT'), throwsA(isA<SimulatedCrash>()),
            reason: 'persist=$persistUnsynced point=$point');
        await opened.db.close();
        opened.mainFile.crash();
        opened.mainLog.crash();
        opened.auxFile.crash();
        opened.auxLog.crash();
        opened.superLog.crash();
        faults.crashAt = null;
        await SchemaCommit.recover(journal: opened.superLog, schemas: [
          (name: 'main', database: opened.mainFile, redo: opened.mainLog),
          (name: 'aux', database: opened.auxFile, redo: opened.auxLog),
        ]);
        final mainRows =
            await _rows(opened.mainFile.volatile, 'SELECT v FROM t ORDER BY v');
        final auxRows =
            await _rows(opened.auxFile.volatile, 'SELECT v FROM u ORDER BY v');
        final integrity =
            await _rows(opened.mainFile.volatile, 'PRAGMA integrity_check');
        final auxIntegrity =
            await _rows(opened.auxFile.volatile, 'PRAGMA integrity_check');
        expect(
            integrity,
            [
              ['ok']
            ],
            reason: 'persist=$persistUnsynced point=$point');
        expect(auxIntegrity, [
          ['ok']
        ]);
        const oldMain = [
          ['m']
        ];
        const newMain = [
          ['m'],
          ['x']
        ];
        const oldAux = <List<Object?>>[];
        const newAux = [
          ['m'],
          ['x']
        ];
        final oldPair = _same(mainRows, oldMain) && _same(auxRows, oldAux);
        final newPair = _same(mainRows, newMain) && _same(auxRows, newAux);
        expect(oldPair || newPair, isTrue,
            reason:
                'persist=$persistUnsynced point=$point main=$mainRows aux=$auxRows');
        sawOld = sawOld || oldPair;
        sawNew = sawNew || newPair;
      }
      expect(sawOld, isTrue, reason: 'persist=$persistUnsynced');
      expect(sawNew, isTrue, reason: 'persist=$persistUnsynced');
    }
  });
}

Future<MutableSqliteDatabase> _memory() async {
  final db = await MutableSqliteDatabase.create();
  addTearDown(db.close);
  await db.execute('CREATE TABLE t(v)');
  await db.execute("INSERT INTO t VALUES ('m')");
  await db.execute("ATTACH ':memory:' AS aux");
  await db.execute('CREATE TABLE aux.u(v)');
  return db;
}

final class _Pair {
  _Pair(this.db, this.mainFile, this.mainLog, this.auxFile, this.auxLog,
      this.superLog);
  final MutableSqliteDatabase db;
  final ModelFile mainFile;
  final ModelFile mainLog;
  final ModelFile auxFile;
  final ModelFile auxLog;
  final ModelFile superLog;
}

Future<_Pair> _pair(CrashController faults,
    {Uint8List? mainImage, Uint8List? auxImage}) async {
  final empty =
      mainImage ?? (await MutableSqliteDatabase.create()).exportImage();
  final auxBytes = auxImage ?? Uint8List.fromList(empty);
  final mainFile = ModelFile(empty, faults);
  final mainLog = ModelFile(Uint8List(0), faults);
  final auxFile = ModelFile(auxBytes, faults);
  final auxLog = ModelFile(Uint8List(0), faults);
  final superLog = ModelFile(Uint8List(0), faults);
  final pager = await RollbackJournalPager.open(mainFile, mainLog);
  final db = await MutableSqliteDatabase.fromJournalPager(pager);
  db.schemaCommitJournal = superLog;
  db.openAttachedPager = (_) => RollbackJournalPager.open(auxFile, auxLog);
  return _Pair(db, mainFile, mainLog, auxFile, auxLog, superLog);
}

Future<void> _seed(MutableSqliteDatabase db) async {
  await db.execute("ATTACH 'aux' AS aux");
  await db.execute('CREATE TABLE t(v)');
  await db.execute("INSERT INTO t VALUES ('m')");
  await db.execute('CREATE TABLE aux.u(v)');
}

Future<List<List<Object?>>> _rows(Uint8List image, String sql) async {
  final db = await MutableSqliteDatabase.fromImage(Uint8List.fromList(image));
  try {
    return (await db.query(sql)).rows;
  } finally {
    await db.close();
  }
}

bool _same(List<List<Object?>> left, List<List<Object?>> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i].length != right[i].length) return false;
    for (var column = 0; column < left[i].length; column++) {
      if (left[i][column] != right[i][column]) return false;
    }
  }
  return true;
}
