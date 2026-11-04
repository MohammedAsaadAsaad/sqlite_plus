// Minimal engine-only reproducer for the JavaScript FTS runtime release gate.
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main() async {
  final db = await openInMemory();
  try {
    await db.execute('CREATE VIRTUAL TABLE f USING fts5(body)');
    await db.execute('INSERT INTO f(body) VALUES (?)', ['hello']);
    print((await db.query('SELECT rowid FROM f WHERE f MATCH ?', ['hello']))
        .rows);
  } finally {
    await db.close();
  }
}
