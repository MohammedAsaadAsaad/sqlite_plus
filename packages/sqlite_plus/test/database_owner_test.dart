import 'dart:io';
import 'dart:isolate';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('sqlite-plus-owner-');
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
  });
  String provision({bool wal = true}) {
    final path = '${directory.path}/data.db';
    File(path).writeAsBytesSync(
        File(wal ? 'test/fixtures/wal-base.db' : 'test/fixtures/write.db')
            .readAsBytesSync());
    File('$path${wal ? '-wal' : '-journal'}').writeAsBytesSync([]);
    // Tests validate I/O and ownership; no physical power-loss attestation is
    // inferred for these freshly created temporary directory entries.
    return path;
  }

  test('shared clients serialize updates from multiple isolates', () async {
    final path = provision();
    final owner = await DatabaseOwner.open(path,
        directoryEntriesDurable: true, wal: true);
    try {
      final port = owner.sendPort;
      Future<void> updates() => Isolate.run(() async {
            final client = DatabaseClient.connect(port);
            try {
              for (var i = 0; i < 3; i++) {
                await client.execute('UPDATE notes SET n=n+1 WHERE id=1');
              }
            } finally {
              client.close();
            }
          });
      await Future.wait([updates(), updates()]);
      expect(
          (await owner.client.query('SELECT n FROM notes WHERE id=1')).rows, [
        [BigInt.from(-993)]
      ]);
      await owner.client.checkpoint();
      expect(File('$path-wal').lengthSync(), 0);
    } finally {
      await owner.close();
    }
    final reopened = await DatabaseOwner.open(path,
        directoryEntriesDurable: true, wal: true);
    try {
      expect(
          (await reopened.client.query('SELECT n FROM notes WHERE id=1')).rows,
          [
            [BigInt.from(-993)]
          ]);
    } finally {
      await reopened.close();
    }
  });
  test('transaction scope belongs to its client across messages', () async {
    final path = provision();
    final owner = await DatabaseOwner.open(path,
        directoryEntriesDurable: true, wal: true);
    try {
      final other = DatabaseClient.connect(owner.sendPort);
      await owner.client.execute('BEGIN');
      await owner.client.execute("UPDATE notes SET value='private' WHERE id=1");
      await expectLater(
          other.query('SELECT value FROM notes WHERE id=1'), throwsStateError);
      await expectLater(other.execute('COMMIT'), throwsStateError);
      await expectLater(owner.client.checkpoint(), throwsStateError);
      await owner.client.execute('COMMIT');
      expect((await other.query('SELECT value FROM notes WHERE id=1')).rows, [
        ['private']
      ]);
      other.close();
    } finally {
      await owner.close();
    }
  });
  test('duplicate owner in a separate isolate fails before opening main',
      () async {
    final path = provision();
    final owner = await DatabaseOwner.open(path,
        directoryEntriesDurable: true, wal: true);
    try {
      await expectLater(
          DatabaseOwner.open(path, directoryEntriesDurable: true, wal: true),
          throwsStateError);
      await owner.client
          .execute("UPDATE notes SET value='still-owned' WHERE id=1");
      expect(
          (await owner.client.query('SELECT value FROM notes WHERE id=1')).rows,
          [
            ['still-owned']
          ]);
    } finally {
      await owner.close();
    }
  });
  test(
      'shutdown rolls back an abandoned transaction; clients cannot shut owner',
      () async {
    final path = provision();
    final owner = await DatabaseOwner.open(path,
        directoryEntriesDurable: true, wal: true);
    await owner.client.execute('BEGIN');
    await owner.client.execute('DELETE FROM notes');
    owner.client
        .close(); // Closing the logical default client must not block owner shutdown.
    await owner.close();
    final next = await DatabaseOwner.open(path,
        directoryEntriesDurable: true, wal: true);
    try {
      expect((await next.client.query('SELECT id FROM notes LIMIT 1')).rows, [
        [BigInt.one]
      ]);
    } finally {
      await next.close();
    }
  });
  test('rollback mode persists transactions through the same owner API',
      () async {
    final path = provision(wal: false);
    final owner = await DatabaseOwner.open(path, directoryEntriesDurable: true);
    try {
      await owner.client.execute('SAVEPOINT a');
      await owner.client.execute('DELETE FROM notes WHERE id>2');
      await owner.client.execute('RELEASE a');
      expect((await owner.client.query('SELECT id FROM notes')).rows.length, 2);
      await expectLater(owner.client.checkpoint(), throwsStateError);
    } finally {
      await owner.close();
    }
  });
  test('stale shared-memory and missing sidecars fail without creation',
      () async {
    final path = provision();
    File('$path-shm').writeAsBytesSync([]);
    await expectLater(
        DatabaseOwner.open(path, directoryEntriesDurable: true, wal: true),
        throwsStateError);
    File('$path-shm').deleteSync();
    File('$path-wal').deleteSync();
    await expectLater(
        DatabaseOwner.open(path, directoryEntriesDurable: true, wal: true),
        throwsStateError);
    expect(File('$path-wal').existsSync(), isFalse);
    await expectLater(DatabaseOwner.open(path, directoryEntriesDurable: false),
        throwsUnsupportedError);
  });
  test('SQL exceptions and independent bound blobs survive RPC', () async {
    final owner = await DatabaseOwner.open(provision(),
        directoryEntriesDurable: true, wal: true);
    try {
      await expectLater(owner.client.query('SELECT missing FROM notes'),
          throwsA(isA<SqlException>()));
      expect(
          (await owner.client.query('SELECT ?', ["'; DELETE FROM notes; --"]))
              .rows,
          [
            ["'; DELETE FROM notes; --"]
          ]);
    } finally {
      await owner.close();
    }
  });
}
