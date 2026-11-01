/// Optional Pure Dart dart:io adapter. Do not import this library on the Web.
library;

import 'src/sql/database.dart';
import 'src/storage/official_file_storage.dart';

export 'src/storage/read_only_file_storage_backend.dart';
export 'src/storage/durable_file_storage_backend.dart';
export 'src/storage/official_file_storage.dart'
    show OfficialFileStorage, SqliteLock;
export 'src/connection/database_owner.dart';

/// Opens [path] for reading. A pending `-wal` or hot `-journal` is recovered
/// in memory. The file and its sidecars are not modified. A shared SQLite
/// lock is held until the database is closed.
Future<SqliteDatabase> openReadOnlyFile(String path,
    {int maxImageBytes = 64 * 1024 * 1024}) async {
  final storage =
      await OfficialFileStorage.open(path, maxImageBytes: maxImageBytes);
  try {
    return await SqliteDatabase.openReadOnly(storage);
  } catch (_) {
    await storage.close();
    rethrow;
  }
}
