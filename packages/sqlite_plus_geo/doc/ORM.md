# ORM

Import `package:sqlite_plus_geo/orm.dart`. The codec stores EWKB in a `BLOB`. The generator is unchanged and does not emit a geometry annotation.

```dart
final location = Column<Facility, GeoPoint>(
  property: 'location',
  codec: const GeoPointCodec(srid: 4326),
  read: (facility) => facility.location,
  write: (facility, value) => facility.location = value,
);
```

`GeoPointCodec` rejects a different SRID on write and rejects a non-point on read. `GeoGeometryCodec` accepts any geometry unless `type` or `srid` is set. `Codecs.nullable` wraps either codec.

`whereSpatial` is not a generated query method. Filter with `GeoSession.search`, `nearest`, or `join` on the same `MutableSqliteDatabase`. Register spatial SQL with `SqlitePlusGeo.register` if the statement uses `ST_*`. Re-register after `fromImage`.

The spatial index is created by `GeoSession.createSpatialTable` or by a hand-written `rtree` virtual table. The ORM `DbModules.rtree` path remains the engine's rectangle table and is separate from a geometry blob column.
