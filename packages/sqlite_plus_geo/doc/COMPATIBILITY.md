# Compatibility

This package is not a PostGIS, SpatiaLite, OGC Simple Features, or GeoPackage certification. The notes below are the differences that the tests and the source fix in place.

| Topic | This package |
|---|---|
| `ST_SetSRID` | metadata only |
| `ST_Transform` | WGS84 Web Mercator and WGS84 UTM only |
| `ST_DWithin` | third argument is planar; fourth argument true means spheroidal metres for points |
| `ST_Area` | planar, including square degrees on SRID 4326 |
| `ST_AreaSphere` | authalic sphere, not an ellipsoid |
| `ST_Azimuth` | radians, matching the PostGIS unit for the geographic case |
| `ST_ConcaveHull` | points only; ratio is an edge-length fraction, not a target percent |
| `ST_Buffer` | polygon approximation |
| `ST_Collect` | one-argument form is the aggregate |
| Empty / empty `ST_Intersects` | false |
| Empty / empty `ST_Equals` | false |
| GeoJSON | RFC 7946, no crs member on write |
| SQL planner | no spatial index in `EXPLAIN QUERY PLAN` |
| R-tree | sqlite_plus float32 nodes, boxes expanded outward |
| Geographic nearest of a line or polygon | minimum vertex geodesic |

`ST_Polygonize` and ellipsoidal area are not registered. Shapefile, KML, GPX, FlatGeobuf, and GeoPackage are not implemented.
