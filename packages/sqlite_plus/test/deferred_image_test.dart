import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('a rolled-back transaction keeps an earlier unmaterialized commit',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database
        .execute('CREATE TABLE rows(id INTEGER PRIMARY KEY, name TEXT)');
    await database.execute('BEGIN');
    await database.execute('INSERT INTO rows(name) VALUES (?)', ['first']);
    await database.execute('COMMIT');
    await database.execute('BEGIN');
    await database.execute('INSERT INTO rows(name) VALUES (?)', ['second']);
    await database.execute('ROLLBACK');
    final rows = await database.query('SELECT name FROM rows ORDER BY id');
    expect(rows.rows.map((row) => row.single), ['first']);
  });

  test('a schema read between commits does not hide a deferred row', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database
        .execute('CREATE TABLE rows(id INTEGER PRIMARY KEY, name TEXT)');
    await database.execute("INSERT INTO rows(name) VALUES ('one')");
    await database
        .query("SELECT tbl_name FROM sqlite_schema WHERE type='trigger'");
    await database.execute("INSERT INTO rows(name) VALUES ('two')");
    final rows = await database.query('SELECT name FROM rows ORDER BY id');
    expect(rows.rows.map((row) => row.single), ['one', 'two']);
  });

  test('rollback to a savepoint drops only the later deferred insert',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database
        .execute('CREATE TABLE rows(id INTEGER PRIMARY KEY, name TEXT)');
    await database.execute('BEGIN');
    await database.execute("INSERT INTO rows(name) VALUES ('kept')");
    await database.execute('SAVEPOINT mark');
    await database.execute("INSERT INTO rows(name) VALUES ('dropped')");
    await database.execute('ROLLBACK TO mark');
    await database.execute('COMMIT');
    final rows = await database.query('SELECT name FROM rows ORDER BY id');
    expect(rows.rows.map((row) => row.single), ['kept']);
  });

  test('rollback undoes a schema change made after a deferred insert',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database
        .execute('CREATE TABLE rows(id INTEGER PRIMARY KEY, name TEXT)');
    await database.execute("INSERT INTO rows(name) VALUES ('kept')");
    await database.execute('BEGIN');
    await database.execute("INSERT INTO rows(name) VALUES ('temporary')");
    await database.execute('ALTER TABLE rows ADD COLUMN extra TEXT');
    await database.execute('ROLLBACK');
    final rows = await database.query('SELECT name FROM rows ORDER BY id');
    expect(rows.rows.map((row) => row.single), ['kept']);
    final columns = await database.query('PRAGMA table_info(rows)');
    expect(columns.rows.map((row) => row[1]), ['id', 'name']);
  });
}
