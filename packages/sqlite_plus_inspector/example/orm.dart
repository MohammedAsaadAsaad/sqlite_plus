import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_orm.dart';
import 'model.dart';

Future<void> main() async {
  final engine = await openInMemory();
  final inspector =
      SqlInspector(options: InspectorOptions(repeatedReadThreshold: 2));
  final context = DbContext(
      inspector.ormConnection(MutableDatabaseConnection(engine)),
      DbModel([type]));
  try {
    await context.migrations.ensureCreated();
    final products = context.set(type);
    products.add(Product(BigInt.one, 'one', 4));
    products.add(Product(BigInt.two, 'two', 5));
    await context.saveChanges();
    inspector.clear();
    await inspector.scope('load-products', () async {
      await products.query.where(id.eq(BigInt.one)).toList();
      await products.query.where(id.eq(BigInt.two)).toList();
    });
    final scope = inspector.snapshot().scopes.single;
    if (scope.queryCount != 2 || scope.repeatedReads.single.count != 2) {
      throw StateError('ORM inspector assertions');
    }
    print('ORM inspector assertions passed: typed queries and repeated reads.');
  } finally {
    await context.close();
    await engine.close();
    inspector.close();
  }
}
