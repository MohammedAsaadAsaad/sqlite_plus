import 'dart:io';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_io.dart';
import 'package:test/test.dart';
import '../example/model.dart';

void main() {
  test('raw file owner/client adapters keep transactions and ownership',
      () async {
    final dir = Directory.systemTemp.createTempSync('inspector-file-');
    final owner = await openDatabase('${dir.path}/test.db');
    try {
      final inspector = SqlInspector();
      final db = inspector.file(owner);
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
      await db.execute('BEGIN');
      await db.execute('INSERT INTO t VALUES(1)');
      expect(db.inTransaction, isTrue);
      expect(
          (await db.query('SELECT * FROM t')).rows.single.single, BigInt.one);
      await db.execute('ROLLBACK');
      expect((await db.query('SELECT * FROM t')).rows, isEmpty);
      expect(inspector.snapshot().executeCount, 4);
      final client = inspector.client(DatabaseClient.connect(owner.sendPort));
      await client.close();
      await expectLater(client.query('SELECT * FROM t'), throwsStateError);
      expect((await db.query('SELECT * FROM t')).rows, isEmpty);
      await expectLater(db.explain('SELECT * FROM t'), throwsUnsupportedError);
      await db.close();
    } finally {
      await owner.close();
      dir.deleteSync(recursive: true);
    }
  });

  test('ORM file bridge captures queries and reopens saved data', () async {
    final dir = Directory.systemTemp.createTempSync('inspector-orm-file-');
    final path = '${dir.path}/test.db';
    final inspector = SqlInspector();
    try {
      final owner = await openDatabase(path);
      final connection = inspector.ormFile(owner);
      final context = DbContext(connection, DbModel([type]));
      expect(() => DbContext(inspector.ormFile(owner), DbModel([type])),
          throwsA(isA<OrmStateException>()));
      await expectLater(connection.close(), throwsA(isA<OrmStateException>()));
      await context.migrations.ensureCreated();
      await inspector.scope('save-product', () async {
        context.set(type).add(Product(BigInt.one, 'kept', 7));
        await context.saveChanges();
        expect((await context.set(type).query.page(size: 1)).items.single.name,
            'kept');
      });
      await expectLater(
          connection.explain('SELECT * FROM products'), throwsUnsupportedError);
      await context.close();
      final reopened = await openDatabase(path);
      expect(
          (await reopened.rawQuery('SELECT name FROM products')).single['name'],
          'kept');
      await reopened.close();
      expect(inspector.snapshot().scopes.single.queryCount, greaterThan(0));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
