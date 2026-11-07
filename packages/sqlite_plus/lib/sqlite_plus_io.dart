/// Optional Pure Dart dart:io adapter. Do not import this library on the Web.
library;

import 'dart:io';
import 'dart:typed_data';

import 'src/crypto/sqlcipher.dart';
import 'src/sql/database.dart';
import 'src/sql/mutable_database.dart';
import 'src/storage/official_file_storage.dart';

export 'src/crypto/sqlcipher.dart'
    show SqlCipher, SqlCipherDatabase, SqlCipherKeys;
export 'src/storage/read_only_file_storage_backend.dart';
export 'src/storage/durable_file_storage_backend.dart';
export 'src/storage/official_file_storage.dart'
    show OfficialFileStorage, SqliteLock;
export 'src/app/app_commands.dart' show Batch, ConflictAlgorithm, Transaction;
export 'src/connection/database_owner.dart';
export 'src/pagination/pagination.dart';
export 'src/pagination/pagination_io.dart';

export 'src/sql/mutable_database.dart' show MutableSqliteDatabase;

/// Opens [path] as an in-process database image.
///
/// A missing file starts empty and is not created. An existing file is read
/// and is not replaced. Later SQL stays in memory until the caller writes
/// [MutableSqliteDatabase.exportImage]. Register a tokenizer or a module on
/// this connection. [openDatabase] keeps the file and does not receive that
/// registration.
Future<MutableSqliteDatabase> openFileImage(String path) async {
  final file = File(path);
  if (await file.exists()) {
    return MutableSqliteDatabase.fromImage(
        Uint8List.fromList(await file.readAsBytes()));
  }
  return MutableSqliteDatabase.create();
}

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
