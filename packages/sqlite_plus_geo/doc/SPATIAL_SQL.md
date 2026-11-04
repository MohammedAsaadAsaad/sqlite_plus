# Spatial SQL

`SqlitePlusGeo.register(database)` or `GeoSession` installs the functions below. A null argument returns SQL null. Aggregates skip nulls and return null when every input is null. Geometry arguments are EWKB blobs. Geometry results are EWKB. Predicates return integer 1 or 0, which SQL yields as `BigInt`.

`ST_Collect` and `ST_Union` each have a scalar overload and an aggregate overload. The engine stores one function per name and argument count. `ST_Collect(geom)` is the aggregate. `ST_Collect(a, b, ...)` with two or more arguments is the scalar. `ST_Union(geom)` is the aggregate. `ST_Union(a, b)` is the scalar.

An SRID mismatch throws. SRID 0 matches any SRID in the Dart predicates used by these functions. Empty geometries do not intersect, including empty with empty.

## Constructors

| Function | Arguments | Result |
|---|---|---|
| `ST_Point(x, y)` | numbers | point, SRID 0 |
| `ST_Point(x, y, srid)` | numbers | point with that SRID |
| `ST_MakePoint(x, y)` | numbers | same as `ST_Point` |
| `ST_MakePoint(x, y, z)` | numbers | XYZ point |
| `ST_MakePoint(x, y, z, m)` | numbers | XYZM point |
| `ST_GeomFromText(wkt)` | text | parsed geometry, SRID 0 or the EWKT SRID |
| `ST_GeomFromText(wkt, srid)` | text, integer | parsed geometry with that SRID |
| `ST_GeomFromWKB(blob)` | blob | WKB or EWKB |
| `ST_GeomFromWKB(blob, srid)` | blob, integer | SRID applied when the blob has none |
| `ST_GeomFromGeoJSON(text)` | text | RFC 7946, SRID 4326 |
| `ST_MakeLine(g1, g2, ...)` | two or more geometries | one line through every position |
| `ST_MakePolygon(line)` | linestring | polygon shell |
| `ST_MakePolygon(shell, holes)` | linestring and line or multiline | shell plus holes |
| `ST_Collect(a, b, ...)` | two or more | geometry collection |

Malformed text raises `SqlException`. Parameters are the supported way to pass WKT.

## Serialization

`ST_AsText`, `ST_AsEWKT`, `ST_AsBinary`, `ST_AsEWKB`, and `ST_AsGeoJSON` write one geometry. GeoJSON is a text JSON object without a `crs` member. M values cannot be written as GeoJSON. An empty point cannot be written as GeoJSON.

## Properties

| Function | Returns | Empty |
|---|---|---|
| `ST_GeometryType` | `POINT`, `LINESTRING`, `POLYGON`, or a `MULTI` / `GEOMETRYCOLLECTION` name | the type name |
| `ST_SRID` | integer | the stored SRID |
| `ST_SetSRID(g, srid)` | geometry | coordinates unchanged |
| `ST_Dimension` | 0, 1, or 2 | topological dimension |
| `ST_CoordDim` | 2, 3, or 4 | axis count |
| `ST_IsEmpty` | 1 or 0 | 1 |
| `ST_IsValid` | 1 or 0 | 1 for a defined empty geometry |
| `ST_IsValidReason` | text | `Valid Geometry` or a short reason |
| `ST_IsSimple` | 1 or 0 | follows the line and polygon rules |
| `ST_NumGeometries` | integer | 0 for an empty point, line, or polygon |
| `ST_NumPoints`, `ST_NPoints` | coordinate count, including repeated ring closures | 0 |
| `ST_X`, `ST_Y`, `ST_Z`, `ST_M` | number or null | null unless the value is a non-empty point with that axis |
| `ST_Envelope` | polygon | empty polygon |
| `ST_Boundary` | collection or line | empty collection for a point |
| `ST_Centroid`, `ST_PointOnSurface` | point or null | null |

`ST_Contains` requires an interior intersection. A point on a polygon boundary is covered and touched, and it is not contained.

## Predicates

`ST_Equals`, `ST_Intersects`, `ST_Disjoint`, `ST_Contains`, `ST_Within`, `ST_Covers`, `ST_CoveredBy`, `ST_Touches`, `ST_Crosses`, and `ST_Overlaps` take two geometries. `ST_Relate(a, b)` returns the 9-character matrix. `ST_Relate(a, b, pattern)` returns 1 when the matrix matches. `*` matches any digit. `T` matches 0, 1, or 2. `F` matches F.

`ST_DWithin(a, b, distance)` is planar and uses the CRS units. `ST_DWithin(a, b, metres, 1)` is spheroidal metres for points. A negative distance throws. A linestring passed to the geographic form throws.

## Measures

`ST_Distance` is planar. It is 0 when the geometries intersect, otherwise the minimum segment distance. `ST_Length` is planar and is 0 for polygons; the perimeter is `ST_Perimeter`. `ST_Length(g, 1)` and `ST_Perimeter(g, 1)` sum geodesics. `ST_Area` is the absolute shoelace area minus holes. `ST_AreaSphere` is spherical. `ST_Azimuth` is radians.

## Operations

`ST_Buffer(g, distance)` and `ST_Buffer(g, distance, quadrantSegments)` return a polygonal approximation, not a true curve. Quadrant segments must be from 1 to 64. A negative distance is implemented for polygons. Joins default to round. The Dart `GeoBufferParameters` also selects flat or square caps and mitre or bevel joins.

`ST_Union`, `ST_Intersection`, `ST_Difference`, and `ST_SymDifference` overlay polygonal inputs. Two points become a multipoint on union. Two lines intersect as points or overlapping pieces. A line clipped by a polygon keeps a piece whose midpoint is inside. Mixed pairs that are not implemented throw. The overlay refuses more than 800 edges.

`ST_ConvexHull` uses a monotone chain. `ST_ConcaveHull(points, ratio)` accepts points. `ratio` is in `(0, 1]` and is the longest retained edge as a fraction of the convex hull's longest edge. `1` returns the convex hull. This is not the PostGIS target-percent argument.

`ST_Simplify` is Douglas–Peucker. `ST_SimplifyPreserveTopology` returns the original polygon when the simplified ring is invalid. `ST_Snap`, `ST_Reverse`, `ST_Force2D`, `ST_Force3D`, `ST_Translate`, `ST_Scale`, `ST_Rotate`, `ST_LineMerge`, and `ST_MakeValid` match the Dart functions of the same names. `ST_Transform(g, srid)` transforms. `ST_MakeValid` may change a self-intersecting polygon into a multipolygon.

## Aggregates

`ST_Extent(geom)` returns the envelope polygon. `ST_Collect(geom)` returns a collection. `ST_Union(geom)` unions the group in input order.

## Not registered

`ST_Polygonize`, `ST_AreaSpheroid`, and `ST_DistanceSpheroid` for anything other than two points. Calling an unregistered name is an ordinary missing-function SQL error.
