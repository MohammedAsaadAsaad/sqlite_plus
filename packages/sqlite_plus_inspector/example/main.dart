import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';

Future<void> main() async {
  final engine = await openInMemory();
  final inspector =
      SqlInspector(options: InspectorOptions(repeatedReadThreshold: 3));
  final db = inspector.database(engine);
  try {
    await db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT)');
    await db.execute('INSERT INTO products VALUES(1,?),(2,?),(3,?)',
        ['private-a', 'private-b', 'private-c']);
    inspector.clear();
    await inspector.scope('load-products', () async {
      for (final id in [1, 2, 3]) {
        final result =
            await db.query('SELECT name FROM products WHERE id=?', [id]);
        if (result.rows.length != 1) throw StateError('Query assertion');
      }
    });
    final report = inspector.snapshot();
    if (report.records.first.parameters.single != '<integer>' ||
        report.statementCount != 3 ||
        report.groups.single.count != 3 ||
        report.scopes.single.repeatedReads.single.count != 3 ||
        report.toJsonString().contains('private-')) {
      throw StateError('Inspector assertions');
    }
    final plan = await db.explain('SELECT name FROM products WHERE id=?', [1]);
    if (!plan.hasRowidBound || inspector.snapshot().statementCount != 3) {
      throw StateError('Explicit plan assertion');
    }
    print(report.toJsonString());
    print(
        'Inspector assertions passed: redaction, counts, scopes, repetition and explicit plan.');
  } finally {
    await db.close();
    inspector.close();
  }
}
