import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

void main() {
  test('adapter parameters and transaction state use public engine APIs',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final connection = MutableDatabaseConnection(db);
    expect(connection.inTransaction, isFalse);
    await connection.execute('CREATE TABLE t(x)');
    await connection.execute('BEGIN');
    expect(connection.inTransaction, isTrue);
    await connection.execute('INSERT INTO t VALUES(?)', ['bound']);
    expect((await connection.query('SELECT * FROM t')).rows, [
      ['bound']
    ]);
    await connection.execute('ROLLBACK');
    expect(connection.inTransaction, isFalse);
    expect((await connection.query('SELECT * FROM t')).rows, isEmpty);
  });

  test('adapter and underlying database claims exclude other contexts',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final a = MutableDatabaseConnection(db), b = MutableDatabaseConnection(db);
    final first = Object(), second = Object();
    a.claim(first);
    a.claim(first);
    expect(() => a.claim(second), throwsA(isA<OrmStateException>()));
    expect(() => b.claim(first), throwsA(isA<OrmStateException>()));
    expect(() => b.query('SELECT 1'), throwsA(isA<OrmStateException>()));
    expect(() => b.execute('CREATE TABLE bad(x)'),
        throwsA(isA<OrmStateException>()));
    expect(() => b.inTransaction, throwsA(isA<OrmStateException>()));
    expect(() => a.release(second), throwsA(isA<OrmStateException>()));
    await expectLater(a.close(), throwsA(isA<OrmStateException>()));
    expect((await a.query('SELECT 1')).rows, [
      [BigInt.one]
    ]);
    a.release(first);
    b.claim(second);
    expect(() => a.query('SELECT 1'), throwsA(isA<OrmStateException>()));
    expect((await b.query('SELECT 2')).rows, [
      [BigInt.two]
    ]);
    b.release(second);
    a.claim(first);
    a.release(first);
  });

  test('wrapper close is idempotent and preserves a database by default',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final connection = MutableDatabaseConnection(db);
    await connection.close();
    await connection.close();
    expect(
        () => connection.query('SELECT 1'), throwsA(isA<OrmStateException>()));
    expect(() => connection.claim(Object()), throwsA(isA<OrmStateException>()));
    expect((await db.query('SELECT 1')).rows, [
      [BigInt.one]
    ]);
  });

  test('explicit database ownership closes the engine and guards a new lease',
      () async {
    final db = await MutableSqliteDatabase.create();
    final owner = MutableDatabaseConnection(db, closeDatabase: true);
    final other = MutableDatabaseConnection(db);
    final claim = Object();
    other.claim(claim);
    await expectLater(owner.close(), throwsA(isA<OrmStateException>()));
    other.release(claim);
    await owner.close();
    await expectLater(db.query('SELECT 1'), throwsA(isA<StateError>()));
  });
}
