# Changelog

## 0.1.0

- Geometry types, WKT, EWKT, WKB, EWKB, and RFC 7946 GeoJSON.
- Spatial SQL on `sqlite_plus`, EWKB columns, and an R-tree kept in the same savepoint as the row.
- DE-9IM predicates, planar measures, overlay, buffer, hulls, WGS84 geodesy, Web Mercator, and WGS84 UTM.
- `GeoSession.search`, `nearest`, and `join`.
- ORM codecs and streaming GeoJSON and CSV import.
- Documented limits: no SQL planner hook, no GeoPackage, no datum grids, and no measured speedup for the 1,000-point index query.
