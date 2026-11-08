@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';
import 'package:test/test.dart';

void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  for (final encoding in [1, 2, 3]) {
    test(
        'merged values and cross-open integrity match pinned native encoding=$encoding',
        () async {
      final pin =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
      expect(pin.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final dir = await Directory.systemTemp.createTemp('branch_native_');
      final db = await openInMemory(encoding: encoding);
      SqliteBranch? branch;
      try {
        const schema =
            'CREATE TABLE products(tenant INTEGER NOT NULL,sku TEXT NOT NULL,price INTEGER NOT NULL,stock INTEGER NOT NULL,payload BLOB,PRIMARY KEY(tenant,sku)) WITHOUT ROWID';
        const seed =
            "INSERT INTO products VALUES(1,'بسكويت',500,100,X'0102'),(1,'حليب',800,40,NULL)";
        await db.execute(schema);
        await db.execute(seed);
        branch = await SqlitePlusBranches(database: db, sourceId: 'native')
            .create(name: 'prices');
        await branch.database
            .execute("UPDATE products SET price=550 WHERE sku='بسكويت'");
        await branch.database.execute("DELETE FROM products WHERE sku='حليب'");
        await branch.database
            .execute("INSERT INTO products VALUES(2,'تفاح',200,10,NULL)");
        await db.execute("UPDATE products SET stock=97 WHERE sku='بسكويت'");
        await branch.merge();
        const select =
            'SELECT tenant,sku,price,stock,hex(payload) AS payload FROM products ORDER BY tenant,sku';
        final reference = await Process.run(cli, [
          '-json',
          ':memory:',
          "$schema; $seed; UPDATE products SET stock=97 WHERE sku='بسكويت'; UPDATE products SET price=550 WHERE sku='بسكويت'; DELETE FROM products WHERE sku='حليب'; INSERT INTO products VALUES(2,'تفاح',200,10,NULL); $select;"
        ]);
        expect(reference.exitCode, 0, reason: reference.stderr.toString());
        final native = (jsonDecode(reference.stdout.toString()) as List)
            .map((r) => (r as Map).values.toList())
            .toList();
        final actual = (await db.query(select))
            .rows
            .map((r) => r.map((v) => v is BigInt ? v.toInt() : v).toList())
            .toList();
        expect(actual, native);
        final file = File('${dir.path}/main.db');
        await file.writeAsBytes(db.exportImage());
        final opened = await Process.run(cli,
            [file.path, 'PRAGMA integrity_check; PRAGMA foreign_key_check;']);
        expect(opened.exitCode, 0);
        expect(opened.stdout.toString().trim(), 'ok');
      } finally {
        await branch?.close();
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
