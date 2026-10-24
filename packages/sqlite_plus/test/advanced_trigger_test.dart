import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

final class RecordingImagePager implements ImagePager {
  RecordingImagePager(this.image);
  Uint8List image;
  int commits = 0;
  bool fail = false;
  @override
  Future<Uint8List> readImage() async => Uint8List.fromList(image);
  @override
  Future<void> commitImage(Uint8List value) async {
    if (fail) throw StateError('write failure');
    image = Uint8List.fromList(value);
    commits++;
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('foreign-key violations override FAIL and roll back the statement',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY)');
    await db.execute('CREATE TABLE c(pid REFERENCES p)');
    await db.execute('INSERT INTO p VALUES(1)');
    await db.execute('INSERT INTO c VALUES(1)');
    await db.execute(
        "CREATE TRIGGER fail AFTER DELETE ON p BEGIN SELECT RAISE(FAIL,'stop'); END");
    final before = db.exportImage();
    await expectLater(
        db.execute('DELETE FROM p'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect((await db.query('PRAGMA foreign_key_check')).rows, isEmpty);
  });
  test('RAISE FAIL preserves prior rows and BEFORE/AFTER effects', () async {
    for (final timing in ['BEFORE', 'AFTER']) {
      final db = await MutableSqliteDatabase.create();
      addTearDown(db.close);
      await db.execute('CREATE TABLE t(x INT)');
      await db.execute('CREATE TABLE audit(x INT)');
      await db.execute(
          "CREATE TRIGGER stop $timing INSERT ON t WHEN new.x=2 BEGIN INSERT INTO audit VALUES(new.x); SELECT RAISE(FAIL,'stop'); END");
      await expectLater(db.execute('INSERT INTO t VALUES(1),(2),(3)'),
          throwsA(isA<SqlException>()));
      expect(
          (await db.query('SELECT x FROM t ORDER BY x')).rows,
          timing == 'BEFORE'
              ? [
                  [BigInt.one]
                ]
              : [
                  [BigInt.one],
                  [BigInt.two]
                ]);
      expect((await db.query('SELECT x FROM audit')).rows, [
        [BigInt.two]
      ]);
      await db.execute('BEGIN');
      await db.execute('SAVEPOINT s');
      await expectLater(db.execute('INSERT INTO t VALUES(4),(2),(5)'),
          throwsA(isA<SqlException>()));
      expect(db.inTransaction, isTrue);
      await db.execute('ROLLBACK TO s');
      await db.execute('COMMIT');
      expect((await db.query('SELECT x FROM audit')).rows, [
        [BigInt.two]
      ]);
    }
  });
  test('RAISE ROLLBACK ends transactions and clears savepoints', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT)');
    await db.execute(
        "CREATE TRIGGER stop BEFORE INSERT ON t WHEN new.x=2 BEGIN SELECT RAISE(ROLLBACK,'stop'); END");
    await db.execute('INSERT INTO t VALUES(9)');
    await expectLater(db.execute('INSERT INTO t VALUES(1),(2)'),
        throwsA(isA<SqlException>()));
    expect((await db.query('SELECT x FROM t')).rows, [
      [BigInt.from(9)]
    ]);
    await db.execute('BEGIN');
    await db.execute('INSERT INTO t VALUES(8)');
    await db.execute('SAVEPOINT s');
    await expectLater(db.execute('INSERT INTO t VALUES(1),(2)'),
        throwsA(isA<SqlException>()));
    expect(db.inTransaction, isFalse);
    expect((await db.query('SELECT x FROM t')).rows, [
      [BigInt.from(9)]
    ]);
    await expectLater(db.execute('RELEASE s'), throwsA(isA<SqlException>()));
  });
  test(
      'FAIL partial images cross the pager boundary and I/O failure poisons the writer',
      () async {
    final empty = await MutableSqliteDatabase.create();
    final pager = RecordingImagePager(empty.exportImage());
    await empty.close();
    final db = await MutableSqliteDatabase.fromImagePager(pager);
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT)');
    await db.execute(
        "CREATE TRIGGER stop BEFORE INSERT ON t WHEN new.x=2 BEGIN SELECT RAISE(FAIL,'stop'); END");
    final commits = pager.commits;
    await expectLater(db.execute('INSERT INTO t VALUES(1),(2)'),
        throwsA(isA<SqlException>()));
    expect(pager.commits, commits + 1);
    final reopened = await MutableSqliteDatabase.fromImage(pager.image);
    addTearDown(reopened.close);
    expect((await reopened.query('SELECT x FROM t')).rows, [
      [BigInt.one]
    ]);
    pager.fail = true;
    await expectLater(
        db.execute('INSERT INTO t VALUES(3),(2)'), throwsStateError);
    await expectLater(db.query('SELECT * FROM t'), throwsStateError);
  });
  test('OLD/NEW preserve values and collation but have no comparison affinity',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db
        .execute('CREATE TABLE typed(v TEXT COLLATE NOCASE,n NUMERIC,b BLOB)');
    await db.execute('CREATE TABLE hits(x INT)');
    await db.execute('INSERT INTO hits VALUES(0)');
    await db.execute('CREATE TABLE typed_audit(v,b)');
    await db.execute(
        "CREATE TRIGGER typed_guard BEFORE INSERT ON typed WHEN new.v='1' AND new.n=2 -- comment\n BEGIN SELECT RAISE(ABORT,'wrong blob') WHERE typeof(new.b)!='blob'; UPDATE hits SET x=x+1 WHERE new.v='1'; INSERT INTO typed_audit SELECT new.v,new.b WHERE new.n=2; END");
    await db.execute('CREATE TABLE typed_flags(a,b,c)');
    await db.execute(
        "CREATE TRIGGER flags AFTER INSERT ON typed BEGIN INSERT INTO typed_flags SELECT new.v=1,new.n='2',new.v='A'; END");
    await db.execute("INSERT INTO typed VALUES('1','2',X'00ff')");
    expect((await db.query('SELECT x FROM hits')).rows, [
      [BigInt.one]
    ]);
    expect((await db.query('SELECT count(*) FROM typed_audit')).rows, [
      [BigInt.one]
    ]);
    await db.execute(
        "CREATE TRIGGER typed_case AFTER INSERT ON typed WHEN new.v='A' BEGIN UPDATE hits SET x=x+1 WHERE new.v='A'; END");
    await db.execute("INSERT INTO typed VALUES('a',3,X'00')");
    expect((await db.query('SELECT x FROM hits')).rows, [
      [BigInt.two]
    ]);
    expect((await db.query('SELECT * FROM typed_flags ORDER BY rowid')).rows, [
      [BigInt.zero, BigInt.zero, BigInt.zero],
      [BigInt.zero, BigInt.zero, BigInt.one]
    ]);
  });
  test(
      'BEFORE insert sees undefined auto rowids and allocation follows trigger writes',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE assigned(id INTEGER PRIMARY KEY,v INT)');
    await db.execute('CREATE TABLE observed(id INT,rid INT)');
    await db.execute(
        'CREATE TRIGGER observe BEFORE INSERT ON assigned BEGIN INSERT INTO observed VALUES(new.id,new.rowid); END');
    await db.execute(
        'CREATE TRIGGER seed BEFORE INSERT ON assigned WHEN new.v=1 BEGIN INSERT INTO assigned(v) VALUES(2); END');
    expect(
        (await db.execute('INSERT INTO assigned(v) VALUES(1) RETURNING id'))
            .returning!
            .rows,
        [
          [BigInt.two]
        ]);
    expect((await db.query('SELECT id,v FROM assigned ORDER BY id')).rows, [
      [BigInt.one, BigInt.two],
      [BigInt.two, BigInt.one]
    ]);
    expect(
        (await db.query('SELECT id,rid FROM observed'))
            .rows
            .every((row) => row.every((v) => v == -BigInt.one)),
        isTrue);
    await db.execute('DROP TRIGGER seed');
    await db.execute(
        'CREATE TRIGGER follow AFTER INSERT ON assigned WHEN new.v=3 BEGIN INSERT INTO assigned(v) VALUES(4); END');
    expect(
        (await db.execute('INSERT INTO assigned(v) VALUES(3),(3) RETURNING id'))
            .returning!
            .rows,
        [
          [BigInt.from(3)],
          [BigInt.from(5)]
        ]);
    expect(
        (await db.query('SELECT id FROM assigned ORDER BY id')).rows.length, 6);
  });
  test(
      'trigger SELECT sources, subqueries, CTEs and limits retain RAISE context',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INT)');
    await db.execute('CREATE TABLE audit(n INT)');
    await db.execute('INSERT INTO audit VALUES(1)');
    await db.execute(
        "CREATE TRIGGER capacity BEFORE INSERT ON t BEGIN SELECT RAISE(ABORT,'capacity') FROM audit WHERE (SELECT count(*) FROM t)>=2; END");
    await db.execute(
        "CREATE TRIGGER negative BEFORE INSERT ON t WHEN EXISTS(SELECT 1 FROM audit WHERE n=1) BEGIN WITH guard(x) AS (SELECT new.n) SELECT RAISE(ABORT,'negative') FROM guard WHERE x<0; END");
    await db.execute(
        "CREATE TRIGGER disabled BEFORE INSERT ON t BEGIN SELECT RAISE(ABORT,'disabled') FROM audit LIMIT 0; END");
    await db.execute('INSERT INTO t VALUES(1,1),(2,2)');
    final before = db.exportImage();
    await expectLater(
        db.execute('INSERT INTO t VALUES(3,3)'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('DELETE FROM t WHERE id=2');
    await expectLater(
        db.execute('INSERT INTO t VALUES(3,-1)'), throwsA(isA<SqlException>()));
    await db.execute('INSERT INTO t VALUES(3,3)');
    expect((await db.query('SELECT id FROM t ORDER BY id')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
    await expectLater(db.query("SELECT RAISE(ABORT,'outside') FROM t"),
        throwsA(isA<SqlException>()));
  });
  test('recursive_triggers is connection state and defaults off', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect((await db.query('PRAGMA recursive_triggers')).rows, [
      [BigInt.zero]
    ]);
    await db.execute('CREATE TABLE counter(n INT)');
    await db.execute('INSERT INTO counter VALUES(0)');
    await db.execute(
        'CREATE TRIGGER bump AFTER UPDATE ON counter WHEN new.n<5 BEGIN UPDATE counter SET n=n+1; END');
    await db.execute('UPDATE counter SET n=1');
    expect((await db.query('SELECT n FROM counter')).rows, [
      [BigInt.two]
    ]);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute('UPDATE counter SET n=1');
    expect((await db.query('SELECT n FROM counter')).rows, [
      [BigInt.from(5)]
    ]);
    await db.execute('PRAGMA recursive_triggers=OFF');
    await db.execute('BEGIN');
    await db.execute('PRAGMA recursive_triggers=YES');
    await db.execute('ROLLBACK');
    expect((await db.query('PRAGMA recursive_triggers')).rows, [
      [BigInt.one]
    ]);
    await db.execute('UPDATE counter SET n=1');
    expect((await db.query('SELECT n FROM counter')).rows, [
      [BigInt.from(5)]
    ]);
  });
  test('recursive trigger depth errors roll back the complete statement',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=1');
    await db.execute('CREATE TABLE t(n INT)');
    await db.execute('INSERT INTO t VALUES(0)');
    await db.execute(
        'CREATE TRIGGER bounded AFTER UPDATE ON t WHEN new.n<1000 BEGIN UPDATE t SET n=n+1; END');
    await db.execute('UPDATE t SET n=1');
    expect((await db.query('SELECT n FROM t')).rows, [
      [BigInt.from(1000)]
    ]);
    await db.execute('DROP TRIGGER bounded');
    await db.execute('UPDATE t SET n=0');
    await db.execute(
        'CREATE TRIGGER loop AFTER UPDATE ON t BEGIN UPDATE t SET n=n+1; END');
    final before = db.exportImage();
    await expectLater(
        db.execute('UPDATE t SET n=1'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect((await db.query('SELECT n FROM t')).rows, [
      [BigInt.zero]
    ]);
  });
}
