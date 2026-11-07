import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';

final class Replica {
  Replica(this.db, this.changes, this.sync);
  final MutableSqliteDatabase db;
  final SqlitePlusChanges changes;
  final SqlitePlusSync sync;
  static Future<Replica> open(SyncTransport transport,
      {Uint8List? image, String scope = 'shop', String? id}) async {
    final db = image == null
        ? await openInMemory()
        : await MutableSqliteDatabase.fromImage(image);
    try {
      await db.execute('PRAGMA recursive_triggers=ON');
      if (image == null) {
        await db.execute(
            'CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT,price INTEGER)');
      }
      final changes = await SqlitePlusChanges.open(database: db);
      final sync = await SqlitePlusSync.open(
          changes: changes, transport: transport, scope: scope, replicaId: id);
      await sync.register(table: 'products', columns: ['name', 'price']);
      return Replica(db, changes, sync);
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<void> write(String sql, [List<Object?> args = const []]) =>
      changes.transaction((tx) async {
        await tx.execute(sql, args);
      });
  Future<List<List<Object?>>> rows() async =>
      (await db.query('SELECT * FROM products ORDER BY id')).rows;
}

final class Hooks implements SyncTransport {
  Hooks(this.delegate);
  final SyncTransport delegate;
  Future<SyncPushResult> Function(SyncOperation)? onPush;
  Future<SyncPullPage> Function(SyncPullRequest)? onPull;
  @override
  Future<SyncPushResult> push(SyncOperation op) =>
      onPush?.call(op) ?? delegate.push(op);
  @override
  Future<SyncPullPage> pull(SyncPullRequest request) =>
      onPull?.call(request) ?? delegate.pull(request);
}
