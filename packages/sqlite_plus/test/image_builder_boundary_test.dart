import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/src/btree/database_image_builder.dart';
import 'package:test/test.dart';

void main() {
  test('page framing rejects empty interiors except the page-one root', () {
    final image = DatabaseImageBuilder.empty(pageSize: 512);
    final header = DatabaseHeader.decode(image);
    final interior = Uint8List(512);
    final data = ByteData.sublistView(interior);
    interior[0] = 5;
    data.setUint16(5, 512);
    data.setUint32(8, 3);
    expect(
        () => BtreePageHeader.decode(interior, database: header, pageNumber: 2),
        throwsFormatException);
    image[100] = 5;
    ByteData.sublistView(image).setUint32(108, 3);
    expect(
        BtreePageHeader.decode(image, database: header, pageNumber: 1)
            .cellCount,
        0);
  });

  test('schema interior splits never leave a non-root page with zero keys',
      () async {
    var interiors = 0;
    for (final encoding in [1, 2, 3]) {
      for (var count = 65; count <= 155; count++) {
        final image = DatabaseImageBuilder.build(
            DatabaseImageBuilder.empty(pageSize: 512, encoding: encoding), [
          for (var i = 0; i < count; i++)
            ImageObject('table', 't$i', 't$i',
                'CREATE TABLE t$i(a TEXT,b INTEGER,c REAL,d BLOB,e NUMERIC,f TEXT,g TEXT,h TEXT)')
        ]);
        final storage = MemoryStorageBackend();
        await storage.write(0, image);
        final pager = await ReadOnlyPager.open(storage);
        final pending = <int>[1];
        while (pending.isNotEmpty) {
          final page = pending.removeLast();
          final bytes = await pager.readPage(page);
          final data = ByteData.sublistView(bytes);
          final start = page == 1 ? 100 : 0;
          if (bytes[start] != 5) continue;
          final cells = data.getUint16(start + 3);
          if (page != 1) {
            expect(cells, greaterThan(0),
                reason: 'encoding=$encoding count=$count page=$page');
            interiors++;
          }
          for (var i = 0; i < cells; i++) {
            pending.add(data.getUint32(data.getUint16(start + 12 + i * 2)));
          }
          pending.add(data.getUint32(start + 8));
        }
        final records = await BtreeReader(pager).scanTable(1).toList();
        expect(records.length, count);
        await storage.close();
      }
    }
    expect(interiors, greaterThan(0));
  });
}
