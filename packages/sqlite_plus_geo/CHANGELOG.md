# Changelog

## 0.1.4

Depends on `sqlite_plus` ^0.1.12 and `sqlite_plus_orm` ^0.1.11. The README opens `places.db` with `openFileImage`. The library behavior is the 0.1.3 release.

## 0.1.3

Depends on `sqlite_plus` ^0.1.11 and `sqlite_plus_orm` ^0.1.10. The library behavior is the 0.1.2 release.

## 0.1.2

Depends on `sqlite_plus` ^0.1.9 and `sqlite_plus_orm` ^0.1.9. The README opens on `places.db`. The library behavior is the 0.1.1 release.

## 0.1.1

Depends on `sqlite_plus` ^0.1.8 and `sqlite_plus_orm` ^0.1.8. The library behavior is the 0.1.0 release.

## 0.1.0

Depends on `sqlite_plus` ^0.1.7 and `sqlite_plus_orm` ^0.1.7. First publication.

- Geometry types, WKT, EWKT, WKB, EWKB, and RFC 7946 GeoJSON.
- Spatial SQL on `sqlite_plus`, EWKB columns, and an R-tree kept in the same savepoint as the row.
- DE-9IM predicates, planar measures, overlay, buffer, hulls, WGS84 geodesy, Web Mercator, and WGS84 UTM.
- `GeoSession.search`, `nearest`, and `join`.
- ORM codecs and streaming GeoJSON and CSV import.
- Documented limits: no SQL planner hook, no GeoPackage, no datum grids, and no measured speedup for the 1,000-point index query.
