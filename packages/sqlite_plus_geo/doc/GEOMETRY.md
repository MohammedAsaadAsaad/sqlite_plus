# Geometry

`GeoGeometry` is immutable. `==` and `equalsExactly` compare type, SRID, dimension, and coordinates. `geoEqualsTopologically` uses the DE-9IM pattern `T*F**FFF*`. Two empty points compare equal exactly and compare false topologically, because their matrix is `FFFFFFFFF`.

X is easting or longitude. Y is northing or latitude. `GeoPoint(longitude: 34.3, latitude: 31.35)` stores 34.3 in X. `GeoMapPosition` copies those axes for a map widget and does not import one.

## Kinds

| Type | Empty | Notes |
|---|---|---|
| `GeoPoint` | `GeoPoint.empty` | One position, or none |
| `GeoLineString` | empty list | Fewer than two positions is invalid unless empty |
| `GeoLinearRing` | same as a line | Serializes as `LINESTRING`. Not equal to a line with the same positions |
| `GeoPolygon` | no exterior | Shell plus holes. `normalize` makes the shell counter-clockwise and holes clockwise |
| `GeoMultiPoint`, `GeoMultiLineString`, `GeoMultiPolygon` | every part empty | One SRID and one dimension |
| `GeoGeometryCollection` | every part empty | Mixed parts |

`GeoDimension` is `xy`, `xyz`, `xym`, or `xyzm`. A missing or extra Z or M throws at construction. `-0.0` is stored as `0.0`. NaN and infinity throw `GeoException`.

SRID `0` means unset. `withSrid` and `ST_SetSRID` change the number and leave the coordinates where they are. `geoTransform` and `ST_Transform` move the coordinates and set the target SRID.

## Validity

`validate()` reports structural problems: an unclosed ring, fewer than four positions, a self-intersection, a hole outside the shell, or a hole that crosses another hole. A linestring may be valid and not simple. Parsing is strict unless `GeoParseOptions.mode` is `permissive` or `repair`. Repair may change a bowtie polygon into a `MultiPolygon`. Ordinary parsing does not repair.

`GeoLimits.standard` caps a parse at 8 MiB, 1,000,000 coordinates, depth 32, 100,000 parts, and 10,000 rings. Overlay refuses more than 800 edges. Validation throws, rather than guessing, above 2,000 pairwise edges.

## Serialization

| Format | Empty point | SRID | Dimension |
|---|---|---|---|
| WKT | `POINT EMPTY` | argument, or `SRID=n;` in EWKT | `Z`, `M`, `ZM` |
| WKB | 5-byte header | not stored | ISO +1000/+2000/+3000 |
| EWKB | 9-byte header when an SRID is written | flag `0x20000000` | Z `0x80000000`, M `0x40000000` |
| GeoJSON | rejected | not written | Z allowed, M rejected |

WKB is little-endian or big-endian. Child geometries in EWKB do not repeat the SRID. An empty point cannot be nested inside another WKB geometry. GeoJSON follows RFC 7946: longitude, latitude, no `crs` member on write. A `crs` member is an error unless `allowLegacyCrs` is set, and then only the names `CRS84` and `urn:ogc:def:crs:OGC:1.3:CRS84` are accepted. Those names do not reorder axes. `EPSG:4326` as a GeoJSON crs name is rejected.

Coordinate text uses Dart `double.toString()`. WKB stores the IEEE bits of finite coordinates.
