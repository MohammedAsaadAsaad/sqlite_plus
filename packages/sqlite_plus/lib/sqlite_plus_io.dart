/// Optional Pure Dart dart:io adapter. Do not import this library on the Web.
library;

import 'dart:io';
import 'dart:typed_data';

import 'src/crypto/sqlcipher.dart';
import 'src/sql/database.dart';
import 'src/storage/official_file_storage.dart';

export 'src/crypto/sqlcipher.dart'
    show SqlCipher, SqlCipherDatabase, SqlCipherKeys;
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

/// Reads a SQLCipher 4 database file.
///
/// The bytes are decrypted once. Later SQL uses the plaintext image. This does
/// not take a SQLite lock and does not read a `-wal` file.
Future<SqlCipherDatabase> openSqlCipher(String path, String passphrase,
    {int iterations = SqlCipher.iterations, int pageSize = 4096}) async {
  final bytes = await File(path).readAsBytes();
  return SqlCipherDatabase.open(Uint8List.fromList(bytes), passphrase,
      iterations: iterations, pageSize: pageSize);
}

/// Replaces [path] with the current SQLCipher image.
///
/// The whole file is written and flushed. This is not the rollback journal,
/// and a crash during the write can leave a torn file.
Future<void> saveSqlCipher(String path, SqlCipherDatabase database) async {
  final bytes = database.encryptedImage();
  await File(path).writeAsBytes(bytes, flush: true);
}
