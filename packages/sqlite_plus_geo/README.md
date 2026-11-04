# sqlite_plus_geo

Pure Dart geometry, spatial SQL, and R-tree queries for [`sqlite_plus`](../sqlite_plus). The package does not use FFI, GEOS, GDAL, PROJ, SpatiaLite, or a native SQLite extension.

It is not an OGC, PostGIS, SpatiaLite, or GeoPackage certification. The functions that are registered are implemented and tested. Names that are not registered are listed in `SqlitePlusGeo.unsupported` and in [doc/LIMITATIONS.md](doc/LIMITATIONS.md).

## Install

The package lives in this repository:

```yaml
dependencies:
  sqlite_plus: ^0.1.5
  sqlite_plus_geo: ^0.1.0
```

Dart SDK `>=3.6.0 <4.0.0`. Flutter uses the same Dart library. Map widgets stay outside this package. `sqlite_plus_geo/io.dart` uses `dart:io` and is the file helper; the core library accepts a byte stream instead.

## Five minutes

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';

final database = await MutableSqliteDatabase.create();
final geo = GeoSession(database);
await geo.createSpatialTable(
  'facilities',
  geometryColumn: 'location',
  geometryType: GeoGeometryType.point,
  srid: 4326,
);
await geo.insert(
  'facilities',
  geometryColumn: 'location',
  geometry: GeoPoint(longitude: 34.30, latitude: 31.35, srid: 4326),
  values: {'name': 'Clinic'},
);
final nearby = await geo.nearest(
  'facilities',
  geometryColumn: 'location',
  point: GeoPoint(longitude: 34.31, latitude: 31.36, srid: 4326),
  limit: 10,
  maxDistance: 5000,
  metric: GeodesicModel.sphere,
);
```

`GeodesicModel.sphere` measures metres on the authalic sphere. `GeodesicModel.planar` measures the stored axes and must not be read as metres on SRID 4326. `ST_DWithin(a, b, distance)` is planar. `ST_DWithin(a, b, metres, 1)` is spheroidal and accepts points.

X is longitude and Y is latitude. The package does not swap them.

## What is implemented

- Point, line, polygon, multi-geometries, and collections, with XY, XYZ, XYM, and XYZM.
- WKT, EWKT, WKB, EWKB, and RFC 7946 GeoJSON.
- DE-9IM predicates, planar measures, polygonal overlay, polygonal buffers, convex hull, and point concave hull.
- WGS84 geodesy: haversine, Vincenty distance and destination, spherical polygon area.
- EPSG:4326, EPSG:3857, and WGS84 UTM zones 32601–32660 and 32701–32760.
- Spatial columns stored as EWKB, indexed by sqlite_plus `rtree`, with savepoints, validation, and rebuild.
- Dart `search`, `nearest`, and `join`. SQL functions are registered on the connection. `EXPLAIN QUERY PLAN` does not show the spatial index; `SpatialPlan.describe()` does.
- A runtime ORM codec in `sqlite_plus_geo/orm.dart`. The generator does not emit it.
- Streaming GeoJSON and CSV import, and GeoJSON export.

## Examples

```sh
cd packages/sqlite_plus_geo/example && dart run bin/main.dart
```

The program prints the nearest facility, the zone that contains the sample point, the imported feature count, the intersection area, and whether the zone query used the index. The four demos are in `example/lib/demos.dart`.

## Documentation

| Guide | What it covers |
|---|---|
| [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | Engine extension points and what this package does not change |
| [doc/GEOMETRY.md](doc/GEOMETRY.md) | Types, equality, validity, serialization |
| [doc/SPATIAL_SQL.md](doc/SPATIAL_SQL.md) | Registered SQL functions |
| [doc/SPATIAL_INDEXING.md](doc/SPATIAL_INDEXING.md) | R-tree storage and query plans |
| [doc/GEODESY.md](doc/GEODESY.md) | Sphere and ellipsoid |
| [doc/CRS.md](doc/CRS.md) | Built-in projections |
| [doc/PRECISION.md](doc/PRECISION.md) | Exact orientation and floating overlay |
| [doc/ORM.md](doc/ORM.md) | `GeoPointCodec` |
| [doc/PERFORMANCE.md](doc/PERFORMANCE.md) | The 1,000-point measurement |
| [doc/TESTING.md](doc/TESTING.md) | How to run the suite |
| [doc/COMPATIBILITY.md](doc/COMPATIBILITY.md) | Differences from PostGIS |
| [doc/LIMITATIONS.md](doc/LIMITATIONS.md) | Unsupported operations |

## Tests

From `packages/sqlite_plus_geo`, on Dart 3.13.7, Linux x64, at 15:16 Asia/Hebron (EET, UTC+2) on 4 November 2026:

```sh
dart format .
dart analyze --fatal-infos
dart test
```

`dart test` passed 42 tests. The example passed 1 test and `dart run bin/main.dart` printed `Clinic | North | 2 | 2.0 | true`. macOS, Windows, Android, iOS, and Flutter web were not launched for this package.
