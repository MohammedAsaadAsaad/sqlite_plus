import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus/src/btree/database_image_builder.dart';
import 'package:test/test.dart';

void main() {
  test('PBKDF2-HMAC-SHA512 matches the SQLCipher 4 key schedule', () {
    final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final keys = SqlCipher.derive('password', salt, iterations: 1);
    expect(_hex(keys.encryptionKey),
        '4c8e83abe87e8c6797b46b00bc79680111d926586dfb2cfee239d5f2bf9ec2b2');
    expect(_hex(keys.hmacKey),
        '7d724fb11c5f8903a62ae48ee1c6b52bb6ed635aa733a80252e37a9d13e61b37');
    final arabic = SqlCipher.derive('مفتاح', salt, iterations: 1);
    expect(_hex(arabic.encryptionKey),
        'b17ea515e6d02dd51b8ec73a3703ef529f02e96fb37b171db6928b10dfdf4429');
  });

  test('an empty unencrypted image keeps a zero reserve', () {
    final image = DatabaseImageBuilder.empty();
    expect(image.length, 4096);
    expect(image[20], 0);
    expect(ByteData.sublistView(image).getUint16(105), 4096);
    final header = DatabaseHeader.decode(image);
    expect(header.reservedBytes, 0);
    expect(header.usableSize, header.pageSize);
  });

  test('reserved bytes move the cell area and still round-trip a row',
      () async {
    final image = DatabaseImageBuilder.empty(reservedBytes: 80);
    expect(image[20], 80);
    expect(ByteData.sublistView(image).getUint16(105), 4016);
    expect(DatabaseHeader.decode(image).usableSize, 4016);
    final db = await MutableSqliteDatabase.fromImage(image);
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v TEXT)');
    await db.execute('CREATE INDEX t_v ON t(v)');
    await db.execute('INSERT INTO t(v) VALUES (?), (?)', ['kept', 'x' * 5000]);
    await db.execute('UPDATE t SET v = ? WHERE v = ?', ['other', 'kept']);
    await db.execute('DELETE FROM t WHERE v = ?', ['other']);
    final rows = await db.query(
        'SELECT length(v) FROM t INDEXED BY t_v WHERE v = ?', ['x' * 5000]);
    expect(rows.rows.single.single, BigInt.from(5000));
    final exported = db.exportImage();
    expect(exported[20], 80);
    expect(exported.length % 4096, 0);
    expect(exported.length, greaterThan(4096));
    final reopened = await MutableSqliteDatabase.fromImage(exported);
    addTearDown(reopened.close);
    expect((await reopened.query('SELECT count(*) FROM t')).rows.single.single,
        BigInt.one);
  });

  test('auto-vacuum with a reserve is rejected and a short page is rejected',
      () async {
    expect(() => DatabaseImageBuilder.empty(pageSize: 512, reservedBytes: 80),
        throwsArgumentError);
    final image = DatabaseImageBuilder.empty(reservedBytes: 80);
    ByteData.sublistView(image).setUint32(52, 1);
    expect(() => DatabaseImageBuilder.build(image, const []),
        throwsUnsupportedError);
    await expectLater(
        MutableSqliteDatabase.fromImage(image), throwsUnsupportedError);
  });

  test('SQLCipher create, update, delete, and reopen keep the rows', () async {
    final created = await SqlCipherDatabase.create('secret', iterations: 2);
    addTearDown(created.database.close);
    await created.database.execute(
        'CREATE TABLE note(id INTEGER PRIMARY KEY, title TEXT, body TEXT)');
    await created.database.execute(
        'INSERT INTO note(title, body) VALUES (?, ?), (?, ?)',
        ['Kept Garden', 'margin', 'Other', 'x' * 6000]);
    await created.database.execute(
        'UPDATE note SET title = ? WHERE title = ?', ['Kept', 'Kept Garden']);
    await created.database.execute('BEGIN');
    await created.database.execute('DELETE FROM note');
    await created.database.execute('ROLLBACK');
    final file = created.encryptedImage();
    expect(file.sublist(0, 16), created.salt);
    expect(String.fromCharCodes(file.sublist(0, 15)), isNot('SQLite format 3'));
    expect(file.length % 4096, 0);
    final plain = created.database.exportImage();
    expect(String.fromCharCodes(plain.sublist(0, 15)), 'SQLite format 3');
    expect(plain[20], 80);
    final opened = await SqlCipherDatabase.open(file, 'secret', iterations: 2);
    addTearDown(opened.database.close);
    final rows = await opened.database
        .query('SELECT title, length(body) FROM note ORDER BY id');
    expect(rows.rows, [
      ['Kept', BigInt.from(6)],
      ['Other', BigInt.from(6000)]
    ]);
    await opened.database.execute('DELETE FROM note WHERE title = ?', ['Kept']);
    final again = await SqlCipherDatabase.open(
        opened.encryptedImage(), 'secret',
        iterations: 2);
    addTearDown(again.database.close);
    expect(
        (await again.database.query('SELECT title FROM note'))
            .rows
            .single
            .single,
        'Other');
  });

  test('a wrong passphrase, a changed byte, and a swapped page fail closed',
      () async {
    final created = await SqlCipherDatabase.create('secret', iterations: 2);
    addTearDown(created.database.close);
    await created.database.execute('CREATE TABLE t(v TEXT)');
    await created.database
        .execute('INSERT INTO t(v) VALUES (?), (?)', ['one', 'y' * 8000]);
    final file = created.encryptedImage();
    await expectLater(SqlCipherDatabase.open(file, 'other', iterations: 2),
        throwsFormatException);
    final flipped = Uint8List.fromList(file)..[100] ^= 0x01;
    await expectLater(
        SqlCipherDatabase.open(flipped, 'secret', iterations: 2),
        throwsA(predicate<FormatException>(
            (error) => error.message.contains('page authentication failed'))));
    final swapped = Uint8List.fromList(file);
    final pages = swapped.length ~/ 4096;
    expect(pages, greaterThan(2));
    final a = swapped.sublist(4096, 8192);
    swapped.setRange(4096, 8192, swapped.sublist(8192, 12288));
    swapped.setRange(8192, 12288, a);
    await expectLater(SqlCipherDatabase.open(swapped, 'secret', iterations: 2),
        throwsFormatException);
    expect(() => SqlCipher.decrypt(Uint8List(100), 'secret', iterations: 2),
        throwsFormatException);
    expect(
        () => SqlCipher.decrypt(file, 'secret', iterations: 2, pageSize: 2048),
        throwsFormatException);
    expect(
        () => SqlCipher.decrypt(file, 'secret', iterations: 2, pageSize: 512),
        throwsArgumentError);
    expect(() => SqlCipher.encrypt(DatabaseImageBuilder.empty(), 'secret'),
        throwsArgumentError);
    expect(() => SqlCipher.derive('', Uint8List(16)), throwsArgumentError);
    expect(() => SqlCipher.derive('secret', Uint8List(16), iterations: 0),
        throwsArgumentError);
  });

  test('a 1024-byte page and a raw key round-trip', () async {
    final small =
        await SqlCipherDatabase.create('secret', iterations: 2, pageSize: 1024);
    addTearDown(small.database.close);
    await small.database.execute('CREATE TABLE t(v TEXT)');
    await small.database.execute('INSERT INTO t(v) VALUES (?)', ['kept']);
    final opened = await SqlCipherDatabase.open(
        small.encryptedImage(), 'secret',
        iterations: 2, pageSize: 1024);
    addTearDown(opened.database.close);
    expect((await opened.database.query('SELECT v FROM t')).rows.single.single,
        'kept');
    expect(
        () => SqlCipherDatabase.open(small.encryptedImage(), 'secret',
            iterations: 3, pageSize: 1024),
        throwsFormatException);

    final raw = "x'${'ab' * 32}'";
    final salt = Uint8List.fromList(List<int>.filled(16, 7));
    final keyed =
        await SqlCipherDatabase.create(raw, iterations: 2, salt: salt);
    addTearDown(keyed.database.close);
    await keyed.database.execute('CREATE TABLE t(v TEXT)');
    await keyed.database.execute('INSERT INTO t(v) VALUES (?)', ['raw']);
    final file = keyed.encryptedImage();
    expect(file.sublist(0, 16), salt);
    final rawOpen = await SqlCipherDatabase.open(file, raw, iterations: 9);
    addTearDown(rawOpen.database.close);
    expect((await rawOpen.database.query('SELECT v FROM t')).rows.single.single,
        'raw');

    final withSalt = "x'${'cd' * 32}${'11' * 16}'";
    final embedded = await SqlCipherDatabase.create(withSalt, iterations: 2);
    addTearDown(embedded.database.close);
    expect(_hex(embedded.salt), '11' * 16);
    await embedded.database.execute('CREATE TABLE t(v TEXT)');
    await embedded.database.execute('INSERT INTO t(v) VALUES (?)', ['salt']);
    final embeddedOpen =
        await SqlCipherDatabase.open(embedded.encryptedImage(), withSalt);
    addTearDown(embeddedOpen.database.close);
    expect(
        (await embeddedOpen.database.query('SELECT v FROM t'))
            .rows
            .single
            .single,
        'salt');
  });

  test('encrypted FTS5 and R-tree rows survive a reopen', () async {
    final created = await SqlCipherDatabase.create('secret', iterations: 2);
    addTearDown(created.database.close);
    await created.database
        .execute('CREATE VIRTUAL TABLE book_text USING fts5(title, body)');
    await created.database.execute(
        'INSERT INTO book_text(title, body) VALUES (?, ?)',
        ['Kept Garden', 'a garden kept in the margin']);
    await created.database.execute(
        'CREATE VIRTUAL TABLE shelf USING rtree(id, minX, maxX, minY, maxY)');
    await created.database.execute('INSERT INTO shelf VALUES (1, 0, 1, 0, 1)');
    final opened = await SqlCipherDatabase.open(
        created.encryptedImage(), 'secret',
        iterations: 2);
    addTearDown(opened.database.close);
    expect(
        (await opened.database.query(
                'SELECT title FROM book_text WHERE book_text MATCH ?',
                ['kept']))
            .rows
            .single
            .single,
        'Kept Garden');
    expect(
        (await opened.database.query(
                'SELECT id FROM shelf WHERE minX <= 1 AND maxX >= 0 AND minY <= 1 AND maxY >= 0'))
            .rows
            .single
            .single,
        BigInt.one);
  });

  test('a file helper writes ciphertext and reads it back', () async {
    final directory = Directory.systemTemp.createTempSync('sqlcipher-plus');
    addTearDown(() => directory.deleteSync(recursive: true));
    final created = await SqlCipherDatabase.create('secret', iterations: 2);
    addTearDown(created.database.close);
    await created.database.execute('CREATE TABLE t(v TEXT)');
    await created.database.execute('INSERT INTO t(v) VALUES (?)', ['file']);
    final path = '${directory.path}/notes.db';
    await saveSqlCipher(path, created);
    final bytes = File(path).readAsBytesSync();
    expect(
        String.fromCharCodes(bytes.sublist(0, 15)), isNot('SQLite format 3'));
    final opened = await openSqlCipher(path, 'secret', iterations: 2);
    addTearDown(opened.database.close);
    expect((await opened.database.query('SELECT v FROM t')).rows.single.single,
        'file');
  });

  test('SQLCipher 4.5.6 default and low-iteration files open here', () async {
    final low = File('test/fixtures/sqlcipher4-kdf2.db').readAsBytesSync();
    final opened = await SqlCipherDatabase.open(low, 'secret', iterations: 2);
    addTearDown(opened.database.close);
    expect(
        (await opened.database.query('SELECT v FROM t WHERE id = 1'))
            .rows
            .single
            .single,
        'kept');
    expect(
        (await opened.database.query('SELECT length(v) FROM t WHERE id = 2'))
            .rows
            .single
            .single,
        BigInt.from(3000));
    expect(
        (await opened.database.query("SELECT v FROM t WHERE t.v = 'kept'"))
            .rows
            .single
            .single,
        'kept');

    final official =
        File('test/fixtures/sqlcipher4-default.db').readAsBytesSync();
    final defaults = await SqlCipherDatabase.open(official, 'secret');
    addTearDown(defaults.database.close);
    expect(
        (await defaults.database.query('SELECT v FROM t WHERE id = 1'))
            .rows
            .single
            .single,
        'kept');
    await expectLater(SqlCipherDatabase.open(low, 'nope', iterations: 2),
        throwsFormatException);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('SQLCipher 4.5.6 reads a file this engine encrypted', () async {
    final cli = await Process.run('sqlcipher', ['-version']);
    if (cli.exitCode != 0) {
      markTestSkipped('sqlcipher is not installed');
      return;
    }
    final directory = Directory.systemTemp.createTempSync('sqlcipher-cli');
    addTearDown(() => directory.deleteSync(recursive: true));
    final created = await SqlCipherDatabase.create('secret', iterations: 2);
    addTearDown(created.database.close);
    await created.database
        .execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
    await created.database
        .execute('INSERT INTO t(v) VALUES (?), (?)', ['kept', 'z' * 3000]);
    final path = '${directory.path}/ours.db';
    await saveSqlCipher(path, created);
    final read = await Process.run('sqlcipher', [
      path,
      "PRAGMA cipher_default_kdf_iter = 2; PRAGMA key = 'secret'; "
          "SELECT v FROM t WHERE id = 1; "
          "SELECT length(v) FROM t WHERE id = 2; "
          'PRAGMA integrity_check;'
    ]);
    expect(read.exitCode, 0, reason: '${read.stderr}');
    expect(read.stdout.toString().trim().split('\n'),
        ['ok', 'kept', '3000', 'ok']);
    final wrong = await Process.run('sqlcipher', [
      path,
      "PRAGMA cipher_default_kdf_iter = 2; PRAGMA key = 'other'; SELECT v FROM t;"
    ]);
    expect(wrong.exitCode, isNot(0));

    final raw = "x'${'ab' * 32}'";
    final keyed = await SqlCipherDatabase.create(raw, iterations: 2);
    addTearDown(keyed.database.close);
    await keyed.database.execute('CREATE TABLE t(v TEXT)');
    await keyed.database.execute('INSERT INTO t(v) VALUES (?)', ['raw']);
    final rawPath = '${directory.path}/raw.db';
    await saveSqlCipher(rawPath, keyed);
    final rawRead = await Process.run('sqlcipher',
        [rawPath, 'PRAGMA key = "x\'${'ab' * 32}\'"; SELECT v FROM t;']);
    expect(rawRead.exitCode, 0, reason: '${rawRead.stderr}');
    expect(rawRead.stdout.toString().trim().split('\n'), ['ok', 'raw']);

    final theirs = '${directory.path}/theirs.db';
    final written = await Process.run('sqlcipher', [
      theirs,
      "PRAGMA cipher_default_kdf_iter = 2; PRAGMA key = 'secret'; "
          'CREATE TABLE t(v TEXT); INSERT INTO t VALUES (\'bridge\');'
    ]);
    expect(written.exitCode, 0, reason: '${written.stderr}');
    final bridge = await openSqlCipher(theirs, 'secret', iterations: 2);
    addTearDown(bridge.database.close);
    expect((await bridge.database.query('SELECT v FROM t')).rows.single.single,
        'bridge');
  });
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
