# Spatial indexing

`GeoSession.createSpatialTable` creates an integer primary key, the extra columns (default `name TEXT`), a `BLOB` geometry column, a row in `geo_spatial_columns`, and, unless `spatialIndex` is false, a virtual table `geoidx_<table>_<column>` using sqlite_plus `rtree`.

The blob is EWKB. The bounding box is not copied into the blob. Empty geometries are stored and are not indexed, because they intersect nothing.

On insert, update, and delete the row and the index entry share a savepoint. `validateIndex` reports missing, extra, and stale ids. A stale box is one that does not contain the geometry envelope. `rebuildIndex` deletes the R-tree rows and inserts them again. It does not rebuild after every single modification.

The stored float32 minimum is rounded down and the maximum is rounded up, by one float32 step when the nearest float32 would shrink the box. A non-finite float32 throws. A query uses the true double envelope. A box hit is not a result: `search` applies `ST_Intersects`, `ST_Within`, `ST_Contains`, or planar `ST_DWithin` afterwards.

`SpatialPlan.describe()` says whether that index scan ran. SQL `EXPLAIN QUERY PLAN` does not, because sqlite_plus has no spatial planner hook.

`nearest` expands a box until the k-th exact distance is inside the box or every row has been seen. Planar distance uses the coordinate axes. Sphere and ellipsoid distances are metres and require SRID 0 or 4326. For a geometry that is not a point, the geographic distance is the minimum vertex geodesic, not the geodesic distance to an edge. Equal distances are ordered by ascending rowid.

`join` scans the left table and calls `search` on the right index. It is a nested loop, not a custom join operator.

Identifiers must match `^[A-Za-z_][A-Za-z0-9_]{0,62}$`. Index names are limited to 63 characters. Values are bound. WKT from outside the program is passed as a parameter, not concatenated.
