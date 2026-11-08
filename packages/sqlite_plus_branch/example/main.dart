import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';

Future<void> main() async {
  final db = await openInMemory();
  SqliteBranch? draft, restored;
  try {
    await db.execute(
        'CREATE TABLE products(sku TEXT PRIMARY KEY NOT NULL,price INTEGER NOT NULL,stock INTEGER NOT NULL)');
    await db.execute("INSERT INTO products VALUES('BISCUIT-001',500,100)");
    final branches = SqlitePlusBranches(database: db, sourceId: 'my-catalog');
    draft = await branches.create(name: 'new-prices');
    await draft.database.execute('UPDATE products SET price=550');
    await db.execute('UPDATE products SET stock=97');
    final change = (await draft.diff()).single;
    print('${change.table}: ${change.before} -> ${change.after}');

    // Explicit portable checkpoint: includes BOTH base and working SQLite images.
    final archive = await draft.exportArchive();
    restored = await branches.restore(archive);
    final preview = await restored.previewMerge();
    if (preview.conflicts.isNotEmpty) {
      throw StateError('Price and stock edits should merge independently');
    }
    await restored.merge(preview: preview);
    final row =
        (await db.query('SELECT price,stock FROM products')).rows.single;
    if (row[0] != BigInt.from(550) || row[1] != BigInt.from(97)) {
      throw StateError('Expected merged price=550, stock=97');
    }
    // The pre-merge checkpoint can safely retry after source commit.
    final result = await draft.merge();
    if (!result.alreadyMerged) {
      throw StateError('Expected committed merge receipt');
    }
    print('Merged: price=${row[0]}, stock=${row[1]}; retry already merged.');
  } finally {
    await restored?.close();
    await draft?.close();
    await db.close();
  }
}
