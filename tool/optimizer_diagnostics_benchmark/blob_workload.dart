import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'workload.dart';

Future<void> blobWorkload(List<String> args, Reader read) async {
  final mutable = await openInMemory();
  final image = mutable.exportImage();
  final Object db = args[0] == 'mutable'
      ? mutable
      : await SqliteDatabase.openReadOnly(ByteImageStorage(image));
  final blob = Uint8List(1024 * 1024);
  var micros = 0;
  for (var i = 0; i < 20; i++) {
    blob[0] = i;
    final result =
        await read(db, 'SELECT length(?) AS bytes', [blob], args[1] == 'on', 0);
    micros += result.durationUs;
    if (result.result.rows.single.single != BigInt.from(blob.length)) {
      throw StateError('BLOB length changed');
    }
  }
  print(jsonEncode({
    'adapter': args[0],
    'enabled': args[1] == 'on',
    'duration_us': micros,
    'calls': 20,
    'blob_bytes': blob.length,
    'peak_rss': ProcessInfo.maxRss
  }));
  if (db is SqliteDatabase) await db.close();
  await mutable.close();
}
