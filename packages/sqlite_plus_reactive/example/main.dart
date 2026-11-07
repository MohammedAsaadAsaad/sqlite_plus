import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_reactive/sqlite_plus_reactive.dart';

Future<void> main() async {
  final db = await openInMemory();
  await db.execute('PRAGMA recursive_triggers=ON');
  await db.execute(
      'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER)');
  final changes = await SqlitePlusChanges.open(database: db);
  await changes.track(table: 'products');
  final reactive = ReactiveDatabase(changes);
  final results = <ReactiveSnapshot<Map<String, Object?>>>[];
  final query = reactive.watch(
      'SELECT id,name,price FROM products WHERE price<? ORDER BY price,id',
      parameters: [
        20
      ],
      dependencies: {
        'products': {'id', 'name', 'price'}
      },
      keyColumns: [
        'id'
      ]);
  final subscription = query.listen(results.add);
  try {
    await reactive.flush();
    await changes.transaction((tx) =>
        tx.execute("INSERT INTO products VALUES(1,'حليب',10),(2,'شاي',30)"));
    await reactive.flush();
    if (results.length != 2 ||
        results.last.items.single['name'] != 'حليب' ||
        results.last.changes.single.kind != ReactiveChangeKind.added) {
      throw StateError('Initial/filter/change assertions failed');
    }
    await changes.transaction(
        (tx) => tx.execute('UPDATE products SET price=5 WHERE id=2'));
    await reactive.flush();
    if (results.last.items.first['name'] != 'شاي') {
      throw StateError('Order assertion failed');
    }
    print(
        'Reactive assertions passed: lazy initial read, commit, filter, ordering and row diffs.');
  } finally {
    await subscription.cancel();
    await reactive.close();
    await db.close();
  }
}
