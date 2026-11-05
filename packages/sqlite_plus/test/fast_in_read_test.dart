import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('rowid IN matches the scan, including a bound column filter', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, lang TEXT)');
    await database.execute(
        'INSERT INTO items(id, name, lang) VALUES (1,?,?),(2,?,?),(4,?,?)',
        ['biscuit', 'en', 'بسكويت', 'ar', 'milk', 'en']);

    Future<void> same(
        String fast, String slow, List<Object?> parameters) async {
      final left = await database.query(fast, parameters);
      final right = await database.query(slow, parameters);
      expect(left.columns, right.columns, reason: fast);
      expect(left.rows, right.rows, reason: fast);
    }

    await same(
      'SELECT id, name FROM items WHERE id IN (?, ?, ?, ?, ?)',
      'SELECT id, name FROM items WHERE id IN (?, ?, ?, ?, ?) OR 0',
      [4, 1, 4, 9, null],
    );
    expect(
        (await database.query(
                'SELECT id, name FROM items WHERE id IN (?, ?, ?, ?, ?)',
                [4, 1, 4, 9, null]))
            .rows,
        [
          [BigInt.one, 'biscuit'],
          [BigInt.from(4), 'milk'],
        ]);
    await same(
      'SELECT "id", "lang" FROM "items" WHERE "id" IN (?,?,?) AND (lang = ?)',
      'SELECT "id", "lang" FROM "items" WHERE "id" IN (?,?,?) AND (lang = ?) OR 0',
      [1, 2, 4, 'en'],
    );
    await same(
      'SELECT id FROM items WHERE id IN (?,?) AND (lang = ? OR lang = ?)',
      'SELECT id FROM items WHERE +id IN (?,?) AND (lang = ? OR lang = ?)',
      [1, 2, 'en', 'ar'],
    );
    await same(
      'SELECT id FROM items WHERE name IN (?, ?)',
      'SELECT id FROM items WHERE name IN (?, ?) OR 0',
      ['biscuit', 'milk'],
    );
    await same(
      'SELECT id FROM items WHERE id = ?',
      'SELECT id FROM items WHERE id = ? OR 0',
      [2],
    );
    expect(
        (await database.query('SELECT id FROM items WHERE id IN (?)', [
          Uint8List.fromList([1])
        ]))
            .rows,
        isEmpty);
  });
}
