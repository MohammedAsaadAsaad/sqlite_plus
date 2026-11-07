import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:test/test.dart';

void main() {
  test('file client pages preserve transaction ownership and read-only reopen',
      () async {
    final folder = Directory.systemTemp.createTempSync('pagination-file-');
    final memory = await openInMemory();
    final path = '${folder.path}/items.db';
    try {
      await memory.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)');
      await memory.execute('INSERT INTO items VALUES(1),(2),(3)');
      await File(path).writeAsBytes(memory.exportImage(), flush: true);
      await File('$path-journal').writeAsBytes([], flush: true);
      final owner = await openDatabase(path, directoryEntriesDurable: true);
      String token;
      try {
        final first =
            await owner.page(table: 'items', keyColumns: ['id'], size: 1);
        token = first.nextCursor!.encode();
        await owner.client.execute('BEGIN');
        final second = await owner.client.page(
            table: 'items',
            keyColumns: ['id'],
            size: 1,
            after: PageCursor.parse(token));
        expect(second.items.single['id'], BigInt.two);
        expect(owner.client.inTransaction, isTrue);
        await owner.client.execute('ROLLBACK');
      } finally {
        await owner.close();
      }
      final reader = await openReadOnlyFile(path);
      try {
        final page = await reader.page(
            table: 'items',
            keyColumns: ['id'],
            size: 1,
            after: PageCursor.parse(token));
        expect(page.items.single['id'], BigInt.two);
      } finally {
        await reader.close();
      }
    } finally {
      await memory.close();
      folder.deleteSync(recursive: true);
    }
  });
}
