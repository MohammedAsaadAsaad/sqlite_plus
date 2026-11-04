/// Runtime geometry codec for the sqlite_plus ORM.
///
/// The generator does not emit this codec. Build a [Column] with
/// [GeoGeometryCodec] or [GeoPointCodec] in the model that opens the database.
library;

import 'dart:typed_data';

import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// Stores any [GeoGeometry] as EWKB.
final class GeoGeometryCodec extends ValueCodec<GeoGeometry> {
  /// [srid] `0` or null accepts the geometry's own SRID. [type] null accepts
  /// every geometry kind.
  const GeoGeometryCodec({this.srid, this.type});

  /// Required SRID, or null when the caller does not check it.
  final int? srid;

  /// Required geometry kind, or null.
  final GeoGeometryType? type;

  @override
  String get sqlType => 'BLOB';

  @override
  Uint8List encode(GeoGeometry value) {
    if (srid != null && srid != 0 && value.srid != srid) {
      throw GeoException('expected SRID $srid and received ${value.srid}');
    }
    if (type != null && value.type != type) {
      throw GeoException(
        'expected ${type!.wktName} and received ${value.type.wktName}',
      );
    }
    return value.toEwkb();
  }

  @override
  GeoGeometry decode(Object? value) {
    if (value is! Uint8List) {
      throw const GeoException('geometry column is not a blob');
    }
    final geometry = GeoGeometry.fromWkb(value);
    if (type != null && geometry.type != type) {
      throw GeoException(
        'expected ${type!.wktName} and received ${geometry.type.wktName}',
      );
    }
    if (srid != null && srid != 0 && geometry.srid != srid) {
      throw GeoException('expected SRID $srid and received ${geometry.srid}');
    }
    return geometry;
  }
}

/// Stores a [GeoPoint] as EWKB and rejects every other kind on read.
final class GeoPointCodec extends ValueCodec<GeoPoint> {
  /// [srid] is checked on encode. Zero accepts any SRID.
  const GeoPointCodec({this.srid = 4326});

  /// Required SRID.
  final int srid;

  @override
  String get sqlType => 'BLOB';

  @override
  Uint8List encode(GeoPoint value) {
    if (srid != 0 && value.srid != srid) {
      throw GeoException('expected SRID $srid and received ${value.srid}');
    }
    return value.toEwkb();
  }

  @override
  GeoPoint decode(Object? value) {
    if (value is! Uint8List) {
      throw const GeoException('geometry column is not a blob');
    }
    final geometry = GeoGeometry.fromWkb(value);
    if (geometry is! GeoPoint) {
      throw const GeoException('expected POINT');
    }
    return geometry;
  }
}
