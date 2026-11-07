import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  const cli = '/tmp/sqlite-build/sqlite3';
  test('warmed probes after triggered updates match pinned SQLite 3.53.1',
      () async {
    final pin =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
    expect(pin.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const statements = [
      'CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT)',
      'CREATE TABLE edits(id INT)',
      'CREATE TRIGGER changed AFTER UPDATE ON items BEGIN INSERT INTO edits VALUES(new.id); END',
      "INSERT INTO items VALUES(1,'old'),(2,'other')",
    ];
    final prefix = '${statements.join(';')};';
    for (final sql in statements) {
      await db.execute(sql);
    }
    await db.query('SELECT id,name FROM items WHERE id IN (?)', [1]);
    await db.query('SELECT id,name FROM items WHERE name = ?', ['old']);
    const update = "UPDATE items SET name='new' WHERE id=1;";
    await db.execute(update);
    for (final query in [
      "SELECT id,name FROM items WHERE id IN (1)",
      "SELECT id,name FROM items WHERE name='old'",
      "SELECT id,name FROM items WHERE name='new'"
    ]) {
      final native = await Process.run(
          cli, ['-json', ':memory:', '$prefix $update $query;']);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final expected = native.stdout.toString().trim().isEmpty
          ? []
          : jsonDecode(native.stdout.toString()) as List;
      final actual = await db.query(query);
      expect([
        for (final row in actual.rows)
          {'id': (row[0] as BigInt).toInt(), 'name': row[1]}
      ], expected);
    }
  }, skip: !File(cli).existsSync() ? 'Pinned CLI unavailable' : false);
}
