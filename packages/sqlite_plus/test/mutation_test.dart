import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

import 'rollback_pager_test.dart' show ModelFile, CrashController;

void main() {
  Uint8List fixture() => File('test/fixtures/write.db').readAsBytesSync();
  test('record encoder round trips every serial width and encoding', () {
    for (final encoding in [1, 2, 3]) {
      final values = <Object?>[
        null,
        BigInt.zero,
        BigInt.one,
        -BigInt.one,
        for (final bits in [7, 15, 23, 31, 47, 63]) -(BigInt.one << bits),
        (BigInt.one << 63) - BigInt.one,
        1.25,
        '',
        'λ😀',
        Uint8List.fromList([0, 255])
      ];
      expect(
          RecordCodec.decode(RecordEncoder.encode(values, encoding: encoding),
              encoding: encoding),
          values);
      final wide = List<Object?>.filled(130, null);
      expect(
          RecordCodec.decode(RecordEncoder.encode(wide, encoding: encoding),
              encoding: encoding),
          wide);
    }
    expect(() => RecordEncoder.varint(-BigInt.one), throwsRangeError);
    expect(() => RecordEncoder.encode([BigInt.one << 64], encoding: 1),
        throwsA(isA<SqlException>()));
  });
  test('INSERT UPDATE DELETE split/rebuild trees and reclaim old pages',
      () async {
    final db = await MutableSqliteDatabase.fromImage(fixture());
    addTearDown(db.close);
    final added = await db.execute(
        'INSERT INTO notes(value,n) VALUES(?,?), (?,?)',
        ['long-' * 3000, 7, 'short', 8]);
    expect(added.changes, 2);
    expect(added.lastInsertRowid, BigInt.from(2002));
    expect(
        (await db.query('SELECT id,n FROM notes WHERE id>2000 ORDER BY id'))
            .rows,
        [
          [BigInt.from(2001), BigInt.from(7)],
          [BigInt.from(2002), BigInt.from(8)]
        ]);
    final updated = await db.execute(
        'UPDATE notes SET n=n+1,value=? WHERE id>=?', ['updated', 1999]);
    expect(updated.changes, 4);
    expect((await db.query('SELECT value,n FROM notes WHERE id=2001')).rows, [
      ['updated', BigInt.from(8)]
    ]);
    expect((await db.execute('DELETE FROM notes WHERE id<2000')).changes, 1999);
    expect((await db.query('SELECT id FROM notes ORDER BY id')).rows, [
      [BigInt.from(2000)],
      [BigInt.from(2001)],
      [BigInt.from(2002)]
    ]);
    final header = DatabaseHeader.decode(db.exportImage());
    expect(header.validateFileLength(db.exportImage().length),
        header.databaseSize);
    expect(header.freelistPages, greaterThan(0));
    expect((await db.execute('DELETE FROM notes')).changes, 3);
    expect((await db.query('SELECT * FROM notes')).rows, isEmpty);
    final insert = await db
        .execute('INSERT INTO notes VALUES(-1,?,?)', ['negative', null]);
    expect(insert.lastInsertRowid, -BigInt.one);
  });
  test('failed statements are atomic and zero-change statements do not rebuild',
      () async {
    final db = await MutableSqliteDatabase.fromImage(fixture());
    addTearDown(db.close);
    final before = db.exportImage();
    for (final sql in [
      "INSERT INTO notes VALUES(1,'duplicate',0)",
      "INSERT INTO notes VALUES(2001,'ok',0),(1,'duplicate',0)",
      'UPDATE notes SET id=1',
      'UPDATE notes SET id=NULL WHERE id=1',
      'INSERT INTO notes(missing) VALUES(1)',
      'DELETE FROM missing',
      'INSERT INTO notes VALUES(1)',
      'UPDATE notes SET missing=1',
      'INSERT INTO notes VALUES(2001,1,1);DELETE FROM notes',
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before);
    }
    expect((await db.execute('DELETE FROM notes WHERE 0')).changes, 0);
    expect(db.exportImage(), before);
  });
  test('indexed targets update both table and index images', () async {
    final input = File('test/fixtures/sqlite-512.db').readAsBytesSync();
    final db = await MutableSqliteDatabase.fromImage(input);
    addTearDown(db.close);
    final result =
        await db.execute("INSERT INTO sample(value) VALUES('new-indexed')");
    expect(result.changes, 1);
    expect((await db.query("SELECT value FROM sample WHERE id=201")).rows, [
      ['new-indexed']
    ]);
    final storage = MemoryStorageBackend();
    await storage.write(0, db.exportImage());
    final pager = await ReadOnlyPager.open(storage);
    addTearDown(pager.close);
    final catalog = await DatabaseCatalog.read(pager);
    final index = catalog.entries.singleWhere((e) => e.name == 'sample_value');
    expect(
        (await BtreeReader(pager).scanIndex(index.rootPage).toList())
            .any((record) => record.values.first == 'new-indexed'),
        isTrue);
  });
  test('autocommit hot insert is on the rollback file before close', () async {
    final created = await MutableSqliteDatabase.create();
    final empty = created.exportImage();
    await created.close();
    final controller = CrashController();
    final storage = ModelFile(empty, controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(storage, journal);
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    await db.execute(
      'CREATE TABLE bench (id INTEGER PRIMARY KEY, name TEXT NOT NULL, body TEXT NOT NULL, n INTEGER NOT NULL)',
    );
    final createdFile = Uint8List.fromList(storage.durable);
    await db.execute(
      'INSERT INTO bench(id, name, body, n) VALUES (1, ?, ?, ?)',
      ['n1', 'b1', 1],
    );
    expect(storage.durable, isNot(createdFile));
    expect(storage.durable, db.exportImage());
    final rows = await db.query('SELECT n FROM bench WHERE id = 1');
    expect(rows.rows.single.single, BigInt.one);
    final persisted = Uint8List.fromList(storage.durable);
    final persistedJournal = Uint8List.fromList(journal.durable);
    await db.close();
    final reopenedPager = await RollbackJournalPager.open(
      ModelFile(persisted, CrashController()),
      ModelFile(persistedJournal, CrashController()),
    );
    final reopened = await MutableSqliteDatabase.fromJournalPager(
      reopenedPager,
    );
    addTearDown(reopened.close);
    expect(
      (await reopened.query('SELECT COUNT(*), SUM(n) FROM bench')).rows.single,
      [BigInt.one, BigInt.one],
    );
  });
  test('mutation can commit through the explicit durable capability', () async {
    final controller = CrashController();
    final storage = ModelFile(fixture(), controller);
    final journal = ModelFile(Uint8List(0), controller);
    final pager = await RollbackJournalPager.open(storage, journal);
    final db = await MutableSqliteDatabase.fromJournalPager(pager);
    await db.execute('DELETE FROM notes');
    expect(storage.durable, db.exportImage());
    expect(journal.durable.take(28), everyElement(0));
    await db.close();
  });
  test('existing-file adapter performs random writes without initial truncate',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('sqlite-plus-writer-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/existing';
    File(path).writeAsBytesSync([1, 2, 3]);
    // The boolean here exercises the caller contract, not a power-loss claim
    // about this freshly created test directory.
    final file = await DurableFileStorageBackend.openExisting(path,
        directoryEntryIsDurable: true);
    addTearDown(file.close);
    expect(await file.length(), 3);
    await file.write(0, Uint8List.fromList([9]));
    await file.sync();
    expect(File(path).readAsBytesSync(), [9, 2, 3]);
    await file.truncate(2);
    await file.sync();
    expect(File(path).readAsBytesSync(), [9, 2]);
    await expectLater(
        DurableFileStorageBackend.openExisting(path,
            directoryEntryIsDurable: false),
        throwsUnsupportedError);
    final missing = '${directory.path}/missing';
    await expectLater(
        DurableFileStorageBackend.openExisting(missing,
            directoryEntryIsDurable: true),
        throwsA(isA<FileSystemException>()));
    expect(File(missing).existsSync(), isFalse);
  });
  test('cross-tree references and corrupted freelists fail before mutation',
      () async {
    final db = await MutableSqliteDatabase.fromImage(fixture());
    addTearDown(db.close);
    await db.execute('DELETE FROM notes');
    final bytes = await TableImageWriter.replace(fixture(), 'notes', []);
    final header = DatabaseHeader.decode(bytes);
    final data = ByteData.sublistView(bytes);
    final trunk = (header.firstFreelistTrunk - 1) * header.pageSize;
    data.setUint32(trunk + 8, 1);
    await expectLater(
        TableImageWriter.replace(bytes, 'notes', []), throwsFormatException);
  });
  test('raw image writer rejects constrained targets before serialization',
      () async {
    final image = fixture();
    await expectLater(
        TableImageWriter.replace(image, 'guarded', [
          TableRow(BigInt.one, [null])
        ]),
        throwsUnsupportedError);
    expect(image, fixture());
  });
}
