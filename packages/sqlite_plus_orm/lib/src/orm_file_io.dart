import 'dart:io';

import 'package:sqlite_plus/sqlite_plus_io.dart';

import 'orm_file_handle.dart';

/// Opens [path] for [DbSet.openDbFile].
///
/// A missing database file is written as an empty image, and a missing
/// `-journal` is written empty. An existing database file is not replaced.
/// [directoryEntriesDurable] is the caller attestation required by
/// [openDatabase]. It is not a power-loss result. Passing false writes
/// nothing and throws.
Future<OrmFileHandle> openOrmFile(String path,
    {bool directoryEntriesDurable = true}) async {
  if (!directoryEntriesDurable) {
    throw UnsupportedError('Durably provision database and sidecar first');
  }
  await _provision(path);
  final owner = await DatabaseOwner.open(path, directoryEntriesDurable: true);
  final client = owner.client;
  return OrmFileHandle(
    query: (sql, parameters) => client.query(sql, parameters),
    execute: (sql, parameters) => client.execute(sql, parameters),
    inTransaction: () => client.inTransaction,
    close: owner.close,
  );
}

/// Writes an empty database image and an empty `-journal` when either is
/// missing. An existing database file is not replaced or deleted.
Future<void> _provision(String path) async {
  final database = File(path);
  final journal = File('$path-journal');
  if (!await database.exists()) {
    await database.parent.create(recursive: true);
    final created = await MutableSqliteDatabase.create();
    try {
      await database.writeAsBytes(created.exportImage(), flush: true);
    } finally {
      await created.close();
    }
  }
  if (!await journal.exists()) {
    await journal.parent.create(recursive: true);
    await journal.writeAsBytes(const <int>[], flush: true);
  }
}
