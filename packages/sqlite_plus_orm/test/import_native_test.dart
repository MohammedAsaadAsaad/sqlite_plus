@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';
import 'import_test.dart' show Product, type, sku, title, price;

void main() {
  for (final encoding in [1, 2, 3]) {
    test(
        'import empty policy/upsert and cross-open integrity match native encoding=$encoding',
        () async {
      final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
          '/tmp/sqlite-build/sqlite3';
      final pin =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
      expect(pin.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final dir = await Directory.systemTemp.createTemp('import_native_');
      final db = await openInMemory(encoding: encoding);
      final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
      const schema =
          'CREATE TABLE products(id INTEGER PRIMARY KEY,sku TEXT COLLATE NOCASE UNIQUE,title TEXT,price INTEGER NOT NULL)';
      try {
        await db.execute(schema);
        await db.execute(
            "INSERT INTO products VALUES(1,'a','Original',5),(2,'بسكويت','Old',6)");
        final plan = await context.set(type).prepareImport([
          Product('A', '', 7),
          Product('بسكويت', 'Fresh', 8),
          Product('حليب', null, 9)
        ], conflictOn: [
          sku
        ], update: [
          title,
          price
        ], emptyValues: OrmImportEmptyValues.keepExisting);
        await plan.apply(batchSize: 1);
        const select = 'SELECT id,sku,title,price FROM products ORDER BY id';
        final native = await Process.run(cli, [
          '-json',
          ':memory:',
          "$schema; INSERT INTO products VALUES(1,'a','Original',5),(2,'بسكويت','Old',6); INSERT INTO products(sku,title,price) VALUES('A','',7),('بسكويت','Fresh',8),('حليب',NULL,9) ON CONFLICT(sku) DO UPDATE SET title=CASE WHEN excluded.title IS NULL OR (typeof(excluded.title)='text' AND excluded.title COLLATE BINARY='') THEN title ELSE excluded.title END,price=excluded.price; $select;"
        ]);
        expect(native.exitCode, 0, reason: native.stderr.toString());
        final expected = (jsonDecode(native.stdout as String) as List)
            .map((r) => (r as Map).values.toList())
            .toList();
        expect(
            (await db.query(select))
                .rows
                .map((r) => r.map((v) => v is BigInt ? v.toInt() : v).toList())
                .toList(),
            expected);
        final file = File('${dir.path}/main.db');
        await file.writeAsBytes(db.exportImage());
        final check =
            await Process.run(cli, [file.path, 'PRAGMA integrity_check;']);
        expect(check.stdout.toString().trim(), 'ok');
      } finally {
        await context.close();
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
