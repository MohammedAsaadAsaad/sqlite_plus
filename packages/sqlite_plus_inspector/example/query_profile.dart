import 'dart:convert';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_orm.dart';
import 'model.dart';

Future<void> main() async {
  final db = await openInMemory();
  final inspector = SqlInspector();
  final connection = inspector.ormConnection(MutableDatabaseConnection(db));
  final context = DbContext(connection, DbModel([type]));
  try {
    // Product and all Column/EntityType descriptors are explicitly in model.dart.
    await context.migrations.ensureCreated();
    await db.execute("INSERT INTO products VALUES ${[
      for (var i = 1; i <= 200; i++) "($i,'Product $i',${(i * 67) % 200})"
    ].join(',')}");
    final before = db.exportImage();
    final report = await connection.profile(
        'SELECT id,price FROM products WHERE price>=? ORDER BY price,id LIMIT ?',
        parameters: [20, 32]);
    final expected = await context
        .set(type)
        .query
        .where(price.gte(20))
        .orderBy([price.asc(), id.asc()])
        .take(32)
        .asNoTracking()
        .toList();
    if (report.result.rows.map((r) => r.first).toList().toString() !=
        expected.map((p) => p.id).toList().toString()) {
      throw StateError('ORM result mismatch');
    }
    if (report.rowsLoaded != 200 ||
        report.rowsVisited != 200 ||
        report.rowsMatched != 180 ||
        report.sortStrategy != 'bounded-heap') {
      throw StateError('Actual work counters');
    }
    if (db.exportImage().toString() != before.toString()) {
      throw StateError('Source changed');
    }
    final metadata = report.toJson();
    if (metadata.containsKey('sql') ||
        metadata.containsKey('parameters') ||
        metadata['sortComparisons'] != null) {
      throw StateError('Metadata contract');
    }
    print(jsonEncode(metadata));
    print(
        'Explicit query diagnostic assertions passed: result, plan, actual rows, bounds, ORM and source isolation.');
  } finally {
    await context.close();
    inspector.close();
    await db.close();
  }
}
