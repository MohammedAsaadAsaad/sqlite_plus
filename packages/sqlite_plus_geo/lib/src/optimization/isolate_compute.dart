part of '../geo_engine.dart';

/// Which prepared geometry operation [geoComputeIsolated] runs.
enum GeoIsolateOperation {
  /// [geoConvexHull].
  convexHull,

  /// [geoBuffer] at [geoComputeIsolated]'s distance.
  buffer,

  /// [geoSimplify] at [geoComputeIsolated]'s tolerance.
  simplify,
}

/// Runs one geometry operation on a copy of the EWKB bytes.
///
/// The geometry is not shared with the caller. This measures the same
/// algorithm as the in-process call. It is not a claim that the isolate is
/// faster: the bytes are copied both ways.
Future<GeoGeometry> geoComputeIsolated(
  GeoGeometry geometry, {
  required GeoIsolateOperation operation,
  double distance = 0,
  double tolerance = 0,
}) async {
  final bytes = await Isolate.run(
    () => _geoIsolateEntry(
        geometry.toEwkb(), operation.index, distance, tolerance),
  );
  return GeoGeometry.fromWkb(bytes);
}

Uint8List _geoIsolateEntry(
  Uint8List ewkb,
  int operation,
  double distance,
  double tolerance,
) {
  final geometry = GeoGeometry.fromWkb(ewkb);
  final result = switch (GeoIsolateOperation.values[operation]) {
    GeoIsolateOperation.convexHull => geoConvexHull(geometry),
    GeoIsolateOperation.buffer => geoBuffer(geometry, distance),
    GeoIsolateOperation.simplify => geoSimplify(geometry, tolerance),
  };
  return result.toEwkb();
}
