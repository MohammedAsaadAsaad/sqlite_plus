@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';
import 'support/write_model.dart';

void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  for (final encoding in [1, 2, 3]) {
    test(
        'direct update/upsert, collation, versions and triggers match pinned SQLite encoding=$encoding',
        () async {
      final pin =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
      expect(pin.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final db = await openInMemory(encoding: encoding);
      await db.execute(itemSchema);
      const trigger =
          'CREATE TRIGGER adjusted AFTER UPDATE OF price ON items BEGIN UPDATE items SET stock=new.price*2 WHERE id=new.id; END';
      await db.execute(trigger);
      final context =
          DbContext(MutableDatabaseConnection(db), DbModel([itemType]));
      try {
        final items = context.set(itemType);
        await items.upsertMany([Item('abc', price: 5), Item('حليب', price: 2)],
            conflictOn: [tenant, sku], update: [amount], batchSize: 1);
        await items.upsert(Item('ABC', price: 7, stock: 999),
            conflictOn: [tenant, sku], update: [amount]);
        await items.query.update({stock: stock.subtract(2)},
            returning: [sku, stock, revision]);
        const select =
            'SELECT id,tenant,sku,price,stock,revision,hex(payload) AS payload FROM items ORDER BY id';
        final native = await Process.run(cli, [
          '-json',
          ':memory:',
          "PRAGMA encoding='${encoding == 1 ? 'UTF-8' : encoding == 2 ? 'UTF-16le' : 'UTF-16be'}';PRAGMA recursive_triggers=ON;$itemSchema;$trigger;"
              "INSERT INTO items VALUES(NULL,1,'abc',5,10,0,X''),(NULL,1,'حليب',2,10,0,X'');"
              "INSERT INTO items VALUES(NULL,1,'ABC',7,999,0,X'') ON CONFLICT(tenant,sku) DO UPDATE SET price=excluded.price,revision=items.revision+1;"
              "UPDATE items SET stock=stock-2,revision=revision+1;$select;"
        ]);
        expect(native.exitCode, 0, reason: native.stderr.toString());
        final actual = await db.query(select);
        expect([
          for (final row in actual.rows)
            {
              for (var i = 0; i < actual.columns.length; i++)
                actual.columns[i]:
                    row[i] is BigInt ? (row[i] as BigInt).toInt() : row[i]
            }
        ], jsonDecode(native.stdout.toString()));
        final dir = Directory.systemTemp.createTempSync('orm-write-native-');
        try {
          final file = File('${dir.path}/db.sqlite');
          await file.writeAsBytes(db.exportImage());
          final check =
              await Process.run(cli, [file.path, 'PRAGMA integrity_check;']);
          expect(check.stdout.toString().trim(), 'ok');
        } finally {
          dir.deleteSync(recursive: true);
        }
      } finally {
        await context.close();
        await db.close();
      }
    });
  }
}
