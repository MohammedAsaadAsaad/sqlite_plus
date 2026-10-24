import 'dart:typed_data';

import 'database_header.dart';
import 'wal_log.dart';

/// WAL recovery for a stable copy or an exclusively owned database/WAL pair.
/// No shared wal-index or coordination with external live SQLite readers.
abstract final class WalSnapshot {
  static Uint8List recover(Uint8List database, Uint8List wal,
      {int maxImageBytes = 64 * 1024 * 1024}) {
    final header = DatabaseHeader.decode(database);
    if (database.length > maxImageBytes) {
      throw const FormatException('Image limit exceeded');
    }
    if (wal.isEmpty) {
      header.validateFileLength(database.length);
      return Uint8List.fromList(database);
    }
    final log = WalLog.decode(wal, header.pageSize, maxImageBytes);
    if (log.databasePages == null) header.validateFileLength(database.length);
    final pageCount = log.databasePages ?? database.length ~/ header.pageSize;
    final image = Uint8List(pageCount * header.pageSize);
    final copied =
        image.length < database.length ? image.length : database.length;
    image.setRange(0, copied, database);
    for (var number = 1; number <= pageCount; number++) {
      final page = log.pages[number];
      if (page != null) {
        image.setRange(
            (number - 1) * header.pageSize, number * header.pageSize, page);
      } else if (number * header.pageSize > database.length) {
        throw const FormatException('Missing WAL database page');
      }
    }
    return image;
  }

  /// Independent rollback-format image; never changes the source pair.
  static Uint8List rollbackCopy(Uint8List database, Uint8List wal,
      {int maxImageBytes = 64 * 1024 * 1024}) {
    final image = recover(database, wal, maxImageBytes: maxImageBytes);
    final header = DatabaseHeader.decode(image);
    image[18] = 1;
    image[19] = 1;
    final data = ByteData.sublistView(image);
    data.setUint32(28, image.length ~/ header.pageSize);
    data.setUint32(92, header.changeCounter);
    return image;
  }
}
