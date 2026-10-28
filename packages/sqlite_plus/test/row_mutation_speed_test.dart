import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  Future<MutableSqliteDatabase> open() async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute(
        'CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, body TEXT NOT NULL, n INTEGER NOT NULL)');
    return database;
  }

  Future<void> seed(MutableSqliteDatabase database, int count) async {
    await database.execute('BEGIN');
    for (var id = 1; id <= count; id++) {
      await database.execute(
          'INSERT INTO bench(id, name, body, n) VALUES (?, ?, ?, ?)',
          [id, 'n$id', 'b$id', id]);
    }
    await database.execute('COMMIT');
  }

  Future<(int, int)> totals(MutableSqliteDatabase database) async {
    final result =
        await database.query('SELECT COUNT(*), COALESCE(SUM(n), 0) FROM bench');
    final row = result.rows.single;
    return ((row[0] as BigInt).toInt(), (row[1] as BigInt).toInt());
  }

  test('bulk and single-row updates keep the checksum', () async {
    final database = await open();
    const count = 40;
    await seed(database, count);
    final updated = await database.execute('UPDATE bench SET n = n + 1');
    expect(updated.changes, count);
    expect(await totals(database), (count, count * (count + 1) ~/ 2 + count));
    final one =
        await database.execute('UPDATE bench SET n = n + 1 WHERE id = ?', [7]);
    expect(one.changes, 1);
    expect((await totals(database)).$2, count * (count + 1) ~/ 2 + count + 1);
    final named = await database
        .execute('UPDATE bench SET body = ? WHERE bench.id = ?', ['z', 7]);
    expect(named.changes, 1);
    expect(
        (await database.query('SELECT body FROM bench WHERE id = 7'))
            .rows
            .single
            .single,
        'z');
  });

  test('a rolled-back update restores the previous values', () async {
    final database = await open();
    await seed(database, 5);
    await database.execute('BEGIN');
    await database.execute('UPDATE bench SET n = n + 10');
    await database.execute('ROLLBACK');
    expect(await totals(database), (5, 15));
    await database.execute('BEGIN');
    await database.execute('UPDATE bench SET n = 0 WHERE id = 2');
    await database.execute('COMMIT');
    expect(
        (await database.query('SELECT n FROM bench WHERE id = 2'))
            .rows
            .single
            .single,
        BigInt.zero);
  });

  test('delete by rowid, text affinity, and unqualified delete', () async {
    final database = await open();
    await seed(database, 6);
    expect(
        (await database.execute('DELETE FROM bench WHERE id = ?', [2])).changes,
        1);
    expect((await database.execute("DELETE FROM bench WHERE id = '4'")).changes,
        1);
    expect(
        (await database.execute('DELETE FROM bench WHERE oid = ?', [6]))
            .changes,
        1);
    expect(
        (await database.execute("DELETE FROM bench WHERE id = 'nope'")).changes,
        0);
    expect((await database.execute('DELETE FROM bench WHERE id = 3.0')).changes,
        1);
    expect(await totals(database), (2, 1 + 5));
    expect((await database.execute('DELETE FROM bench')).changes, 2);
    expect(
        (await database.query('SELECT changes(), total_changes()')).rows.single,
        [BigInt.two, BigInt.from(12)]);
    expect(await totals(database), (0, 0));
    expect((await database.execute('DELETE FROM bench')).changes, 0);
    await database.execute(
        'INSERT INTO bench(id, name, body, n) VALUES (4, ?, ?, ?)',
        ['n4', 'b4', 4]);
    expect(await totals(database), (1, 4));
  });

  test('a missing coerced rowid still scans the comparison', () async {
    final database = await open();
    await seed(database, 3);
    final removed =
        await database.execute("DELETE FROM bench WHERE id = ' 2 '");
    expect(removed.changes, 1);
    expect((await database.query('SELECT id FROM bench ORDER BY id')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
  });

  test('a rowid change and a non-equality filter stay on the full walk',
      () async {
    final database = await open();
    await seed(database, 4);
    final moved =
        await database.execute('UPDATE bench SET id = 40 WHERE id = 4');
    expect(moved.changes, 1);
    expect(
        (await database.query('SELECT id, n FROM bench WHERE id = 40')).rows, [
      [BigInt.from(40), BigInt.from(4)]
    ]);
    final wide = await database
        .execute("UPDATE bench SET n = 0 WHERE id = 1 OR name = 'n2'");
    expect(wide.changes, 2);
    expect(await totals(database), (4, 7));
  });

  test('unique conflicts leave the stored rows unchanged', () async {
    final database = await open();
    await seed(database, 3);
    final before = database.exportImage();
    await expectLater(
        database.execute("UPDATE bench SET name = 'n1' WHERE id = 2"),
        throwsA(isA<SqlConstraintException>()));
    expect(database.exportImage(), before);
    expect(
        (await database.query('SELECT name FROM bench WHERE id = 2'))
            .rows
            .single
            .single,
        'n2');
    await database.execute("UPDATE bench SET name = 'moved' WHERE id = 2");
    await database.execute(
        'INSERT INTO bench(id, name, body, n) VALUES (8, ?, ?, ?)',
        ['n2', 'b', 8]);
    await expectLater(
        database.execute(
            'INSERT INTO bench(id, name, body, n) VALUES (9, ?, ?, ?)',
            ['moved', 'b', 9]),
        throwsA(isA<SqlConstraintException>()));
    expect(await totals(database), (4, 1 + 2 + 3 + 8));
  });

  test('OR REPLACE removes the conflicting row and OR IGNORE skips it',
      () async {
    final database = await open();
    await seed(database, 2);
    final replaced = await database
        .execute("UPDATE OR REPLACE bench SET name = 'n1' WHERE id = 2");
    expect(replaced.changes, greaterThan(0));
    expect(
        (await database.query('SELECT id, name FROM bench ORDER BY id')).rows, [
      [BigInt.two, 'n1']
    ]);
    await database.execute(
        'INSERT INTO bench(id, name, body, n) VALUES (3, ?, ?, ?)',
        ['n3', 'b3', 3]);
    final ignored = await database
        .execute("UPDATE OR IGNORE bench SET name = 'n1' WHERE id = 3");
    expect(ignored.changes, 0);
    expect(
        (await database.query('SELECT name FROM bench WHERE id = 3'))
            .rows
            .single
            .single,
        'n3');
  });

  test('CHECK, NOT NULL, and RETURNING still apply to a same-rowid update',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute(
        'CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER NOT NULL CHECK (n >= 0))');
    await database.execute("INSERT INTO bench(id, name, n) VALUES (1, 'a', 4)");
    await expectLater(database.execute('UPDATE bench SET n = -1 WHERE id = 1'),
        throwsA(isA<SqlConstraintException>()));
    await expectLater(
        database.execute('UPDATE bench SET name = NULL WHERE id = 1'),
        throwsA(isA<SqlConstraintException>()));
    final returned = await database
        .execute('UPDATE bench SET n = n + 1 WHERE id = 1 RETURNING n, name');
    expect(returned.changes, 1);
    expect(returned.returning!.rows, [
      [BigInt.from(5), 'a']
    ]);
  });

  test('an after-update trigger sees the new row', () async {
    final database = await open();
    await seed(database, 2);
    await database
        .execute('CREATE TABLE log(id INTEGER PRIMARY KEY, msg TEXT)');
    await database.execute(
        "CREATE TRIGGER bench_au AFTER UPDATE ON bench BEGIN INSERT INTO log(msg) VALUES (new.name); END");
    await database.execute("UPDATE bench SET name = 'later' WHERE id = 1");
    expect((await database.query('SELECT msg FROM log')).rows.single.single,
        'later');
    expect(
        (await database.query('SELECT name FROM bench WHERE id = 1'))
            .rows
            .single
            .single,
        'later');
  });

  test('a foreign key rejects a same-rowid parent change', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute('PRAGMA foreign_keys=1');
    await database.execute('CREATE TABLE parent(id INTEGER PRIMARY KEY)');
    await database.execute(
        'CREATE TABLE child(id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES parent(id))');
    await database.execute('INSERT INTO parent(id) VALUES (1)');
    await database.execute('INSERT INTO child(id, parent_id) VALUES (1, 1)');
    await expectLater(
        database.execute('UPDATE child SET parent_id = 9 WHERE id = 1'),
        throwsA(isA<SqlConstraintException>()));
    expect(
        (await database.query('SELECT parent_id FROM child'))
            .rows
            .single
            .single,
        BigInt.one);
  });

  test('a partial unique index rejects only the indexed collision', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute(
        'CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER NOT NULL)');
    await database
        .execute('CREATE UNIQUE INDEX bench_name ON bench(name) WHERE n > 0');
    await database.execute("INSERT INTO bench VALUES (1, 'a', 1), (2, 'a', 0)");
    await expectLater(database.execute("UPDATE bench SET n = 1 WHERE id = 2"),
        throwsA(isA<SqlConstraintException>()));
    expect(
        (await database.query('SELECT n FROM bench WHERE id = 2'))
            .rows
            .single
            .single,
        BigInt.zero);
    await database.execute("UPDATE bench SET name = 'b' WHERE id = 2");
    await database.execute('UPDATE bench SET n = 1 WHERE id = 2');
    expect(
        (await database.query("SELECT n FROM bench WHERE name = 'b'"))
            .rows
            .single
            .single,
        BigInt.one);
  });

  test('a repeated insert, bulk increment, and equality read keep the checksum',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute(
        'CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT NOT NULL, body TEXT NOT NULL, n INTEGER NOT NULL)');
    const count = 30;
    for (var id = 1; id <= count; id++) {
      final inserted = await database.execute(
          'INSERT INTO bench(id, name, body, n) VALUES (?, ?, ?, ?)',
          [id, 'n$id', 'b$id', id]);
      expect(inserted.changes, 1);
      expect(inserted.lastInsertRowid, BigInt.from(id));
    }
    expect(await totals(database), (count, count * (count + 1) ~/ 2));
    final bulk = await database.execute('UPDATE bench SET n = n + 1');
    expect(bulk.changes, count);
    expect((await database.query('SELECT changes()')).rows.single.single,
        BigInt.from(count));
    expect(await totals(database), (count, count * (count + 1) ~/ 2 + count));
    expect(
        (await database.query('SELECT n FROM bench WHERE id = ?', [4]))
            .rows
            .single
            .single,
        BigInt.from(5));
    await database.execute('CREATE INDEX bench_name ON bench(name)');
    expect(
        (await database.query('SELECT id FROM bench WHERE name = ?', ['n9']))
            .rows
            .single
            .single,
        BigInt.from(9));
    expect(
        (await database.query('SELECT body FROM bench WHERE id = ?', [9]))
            .rows
            .single
            .single,
        'b9');
    await database.execute('BEGIN');
    await database.execute('UPDATE bench SET n = n + 1');
    await database.execute('ROLLBACK');
    expect(await totals(database), (count, count * (count + 1) ~/ 2 + count));
  });

  test('delete by id then a fresh insert keeps both checksum and uniqueness',
      () async {
    final database = await open();
    await seed(database, 5);
    for (var id = 1; id <= 5; id++) {
      expect(
          (await database.execute('DELETE FROM bench WHERE id = ?', [id]))
              .changes,
          1);
    }
    expect(await totals(database), (0, 0));
    await seed(database, 5);
    expect(await totals(database), (5, 15));
    await database.execute('DELETE FROM bench WHERE id = id');
    expect(await totals(database), (0, 0));
  });
}
