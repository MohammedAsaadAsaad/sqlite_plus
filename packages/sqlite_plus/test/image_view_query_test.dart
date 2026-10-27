import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('query reads the live image and leaves its bytes unchanged', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute(
        'CREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT, done INT)');
    await database.execute(
        'INSERT INTO notes(title, done) VALUES (?, ?), (?, ?)',
        ['حليب', 0, 'خبز', 1]);
    final before = database.exportImage();
    final open = await database
        .query('SELECT id, title FROM notes WHERE done = ? ORDER BY id', [0]);
    expect(open.columns, ['id', 'title']);
    expect(open.rows, [
      [BigInt.one, 'حليب']
    ]);
    expect(database.exportImage(), before);
    final rolled = database.exportImage();
    await database.execute('BEGIN');
    await database.execute('UPDATE notes SET done = 1 WHERE id = ?', [1]);
    await database.execute('ROLLBACK');
    expect((await database.query('SELECT done FROM notes WHERE id = 1')).rows, [
      [BigInt.zero]
    ]);
    expect(database.exportImage(), rolled);
  });
}
