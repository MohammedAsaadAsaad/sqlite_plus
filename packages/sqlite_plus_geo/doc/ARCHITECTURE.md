# Architecture

`sqlite_plus_geo` is a library on top of `sqlite_plus` 0.1.5. It does not add a second database engine and it does not modify the engine sources.

## Reused from sqlite_plus

- `MutableSqliteDatabase` executes SQL, stores BLOBs, and owns transactions.
- `SqlFunctionRegistry.registerScalar` and `registerAggregate` install the `ST_*` functions. A callback that throws `GeoException` is converted to `SqlException` before it leaves the registry, because the registry replaces any other exception with `User function ... failed`.
- `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` wrap each geometry insert, update, and delete. A caller that already ran `BEGIN` keeps that transaction; `RELEASE` only drops the savepoint.
- `CREATE VIRTUAL TABLE ... USING rtree(id, minX, maxX, minY, maxY)` is the persistent spatial index. The node codec stores coordinates as float32. This package expands each stored box outward to the next float32 so the stored box contains the true double envelope.
- `exportImage` / `fromImage` reopen the database. Functions must be registered again. The R-tree rows are part of the image.

## Not present in the engine

These were checked in the engine source, not assumed from the docs:

- There is no `registerFunction` beyond `SqlFunctionRegistry`.
- There is no planner hook that rewrites `ST_Intersects` into an index lookup. `EXPLAIN QUERY PLAN` therefore does not mention the spatial index.
- There is no geometry column type. Geometry is a `BLOB` plus a row in `geo_spatial_columns`.
- The R-tree cursor reads every leaf on `filter` and does not consume a bounding-box constraint. A SQL join of the table to the R-tree repeats that scan. `GeoSession.search` scans the index once, keeps the ids whose boxes overlap, then loads those rows and applies the exact predicate.
- `geopoly` exists and is not used as the general geometry index.

## Layout

`lib/src/geo_engine.dart` is one library with parts, so geometry, predicates, and SQL share private helpers without an import cycle. `lib/orm.dart` and `lib/io.dart` are separate libraries. The ORM codec depends on `sqlite_plus_orm`. The file helpers depend on `dart:io`. The core library does not.

## Risks

- A float32 index can return a box that is slightly larger than the geometry. The exact predicate removes those false positives. The outward rounding is what prevents a false negative.
- Overlay vertices are IEEE doubles after an exact intersection test. Area identities on convex polygons were checked to `1e-3`. Self-intersecting input is rejected by `isValid` and is not a defined overlay result until `geoMakeValid`.
- Vincenty throws when it does not converge. It does not fall back to haversine.
- Datum grids are not shipped. `ST_Transform` only runs the built-in WGS84 projections.
