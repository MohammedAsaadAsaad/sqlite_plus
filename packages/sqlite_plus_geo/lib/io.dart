/// File import and export. Import `sqlite_plus_geo.dart` on Flutter web and
/// pass a byte stream to [GeoExchange.importGeoJsonStream] instead of this
/// library.
library;

import 'dart:io';

import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';

/// Reads [filePath] and inserts features into an existing spatial table.
extension GeoFileImport on GeoSession {
  /// [geometryColumn] defaults to `geometry`. [batchSize] rows share one
  /// transaction. A cancelled import keeps the batches already committed.
  Future<GeoImportProgress> importGeoJson({
    required String filePath,
    required String table,
    String geometryColumn = 'geometry',
    int batchSize = 1000,
    bool skipInvalid = false,
    GeoParseOptions options = const GeoParseOptions(),
    void Function(GeoImportProgress progress)? onProgress,
  }) {
    return importGeoJsonStream(
      bytes: File(filePath).openRead(),
      table: table,
      geometryColumn: geometryColumn,
      batchSize: batchSize,
      skipInvalid: skipInvalid,
      options: options,
      onProgress: onProgress,
    );
  }

  /// Writes one FeatureCollection. The file is replaced.
  Future<void> exportGeoJsonFile({
    required String filePath,
    required String table,
    required String geometryColumn,
    Iterable<String>? propertyColumns,
  }) async {
    final sink = File(filePath).openWrite();
    try {
      await exportGeoJson(
        table: table,
        geometryColumn: geometryColumn,
        sink: sink,
        propertyColumns: propertyColumns,
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}
