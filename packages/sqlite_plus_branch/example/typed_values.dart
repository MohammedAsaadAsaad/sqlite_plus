import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';

/// Shared VM/JS checks: integral REAL equivalence, exact 64-bit keys and BLOBs.
Future<void> main() async {
  final db = await openInMemory();
  await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,value,payload BLOB)');
  final id = BigInt.parse('9223372036854775807');
  await db.execute('INSERT INTO t VALUES(?,?,?)', [
    id,
    1,
    Uint8List.fromList([0, 255])
  ]);
  final manager = SqlitePlusBranches(database: db, sourceId: 'typed');
  final branch = await manager.create(name: 'typed');
  SqliteBranch? restored;
  try {
    await branch.database.execute('UPDATE t SET value=?', [1.0]);
    if ((await branch.diff()).isNotEmpty) {
      throw StateError('Equal integer/real values should compare equal');
    }
    await branch.database.execute('UPDATE t SET value=?,payload=?', [
      1.5,
      Uint8List.fromList([2, 3])
    ]);
    restored = await manager.restore(await branch.exportArchive());
    final change = (await restored.diff()).single;
    if (change.key['id'] != id) throw StateError('64-bit key');
    await restored.merge();
    final row = (await db.query('SELECT id,value,payload FROM t')).rows.single;
    final payload = row[2] as Uint8List;
    if (row[0] != id || row[1] != 1.5 || payload[0] != 2 || payload[1] != 3) {
      throw StateError('Typed checkpoint/merge');
    }
    print('Typed branch assertions passed.');
  } finally {
    await restored?.close();
    await branch.close();
    await db.close();
  }
}
