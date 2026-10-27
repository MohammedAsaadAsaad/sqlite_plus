import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('pubspec does not depend on WASM or native SQLite', () {
    final text = File('pubspec.yaml').readAsStringSync().toLowerCase();
    expect(text.contains('wasm'), isFalse);
    expect(text.contains('sqlite3'), isFalse);
    expect(text.contains('ffi'), isFalse);
  });

  test('a missing browser interface falls back to memory', () async {
    final opened = await openBrowserStorage(name: 'notes');
    expect(opened.storage, isA<MemoryStorageBackend>());
    expect(opened.capabilities.canRead, isTrue);
    expect(opened.capabilities.canWrite, isTrue);
    expect(opened.capabilities.durabilityPromised, isFalse);
    expect(opened.capabilities.placement, StoragePlacement.memory);
    requireWritable(opened.capabilities);
    await opened.storage.write(0, Uint8List.fromList([1, 2, 3]));
    await opened.storage.close();
    final again = await openBrowserStorage(name: 'notes');
    expect(await again.storage.length(), 0);
    expect(again.capabilities.placement, StoragePlacement.memory);
    await again.storage.close();
  });

  test('an explicit null probe is the same missing interface', () async {
    final opened =
        await openBrowserStorage(name: 'notes', probe: () async => null);
    expect(opened.capabilities.placement, StoragePlacement.memory);
    await opened.storage.close();
  });

  test('read-only and promised browser flags are rejected by the caller', () {
    expect(
        () => requireWritable(StorageCapabilities.readOnly), throwsStateError);
    expect(
        () => requireWritable(const StorageCapabilities(
            canRead: true,
            canWrite: true,
            durabilityPromised: true,
            placement: StoragePlacement.browser)),
        throwsStateError);
  });

  test('a simulated browser store keeps the image across close and open',
      () async {
    final store = MemoryBrowserByteStore();
    final opened =
        await openBrowserStorage(name: 'notes', probe: () async => store);
    expect(opened.capabilities.canRead, isTrue);
    expect(opened.capabilities.canWrite, isTrue);
    expect(opened.capabilities.durabilityPromised, isFalse);
    expect(opened.capabilities.placement, StoragePlacement.browser);
    final database = await MutableSqliteDatabase.create();
    await database
        .execute('CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)');
    await database.execute("INSERT INTO notes(body) VALUES ('kept')");
    await opened.storage.truncate(0);
    await opened.storage.write(0, database.exportImage());
    await database.close();
    await opened.storage.close();

    final reopened =
        await openBrowserStorage(name: 'notes', probe: () async => store);
    final length = await reopened.storage.length();
    final bytes = Uint8List(length);
    expect(await reopened.storage.read(0, bytes), length);
    final database2 = await MutableSqliteDatabase.fromImage(bytes);
    expect((await database2.query('SELECT body FROM notes')).rows, [
      ['kept']
    ]);
    expect(reopened.capabilities.durabilityPromised, isFalse);
    await database2.close();
    await reopened.storage.close();
  });

  test('bytes stay local until sync, and the store keeps its own copy',
      () async {
    final store = MemoryBrowserByteStore();
    final opened =
        await openBrowserStorage(name: 'blob', probe: () async => store);
    final input = Uint8List.fromList([4, 5, 6]);
    await opened.storage.write(1, input);
    input[0] = 9;
    expect(await store.read('blob'), isNull);
    await opened.storage.sync();
    expect(await store.read('blob'), [0, 4, 5, 6]);
    final aliased = await store.read('blob');
    aliased![0] = 8;
    expect(await store.read('blob'), [0, 4, 5, 6]);
    await opened.storage.truncate(2);
    await opened.storage.sync();
    expect(await store.read('blob'), [0, 4]);
    await expectLater(opened.storage.write(-1, Uint8List(1)), throwsRangeError);
    await expectLater(opened.storage.read(-1, Uint8List(1)), throwsRangeError);
    await expectLater(opened.storage.truncate(-1), throwsRangeError);
    await opened.storage.close();
    await expectLater(opened.storage.length(), throwsStateError);
    expect(await store.read('blob'), [0, 4]);
  });

  test('empty, slash, and NUL names are rejected', () async {
    await expectLater(openBrowserStorage(name: ''), throwsArgumentError);
    await expectLater(openBrowserStorage(name: 'a/b'), throwsArgumentError);
    await expectLater(openBrowserStorage(name: r'a\b'), throwsArgumentError);
    await expectLater(
        openBrowserStorage(name: 'a\u0000b'), throwsArgumentError);
  });

  test('a thrown probe is not reported as a successful browser open', () {
    expect(
        openBrowserStorage(
            name: 'notes',
            probe: () => Future<BrowserByteStore?>.error(StateError('down'))),
        throwsStateError);
  });
}
