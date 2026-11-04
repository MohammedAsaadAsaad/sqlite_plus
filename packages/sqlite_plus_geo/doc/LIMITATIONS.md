# Limitations

- The SQL planner does not choose a spatial index. Use `GeoSession.search`, `nearest`, or `join` when the index should run. `SpatialPlan.describe()` is the diagnostic.
- At 1,000 uniform points the indexed box query was slower than a table scan. See [PERFORMANCE.md](PERFORMANCE.md). Sizes above 1,000 were not measured.
- The R-tree is not an R\*-tree. Node capacity is the engine's. Bulk load is a series of inserts, not a packed build.
- Overlay supports the polygonal, point, and line cases named in [SPATIAL_SQL.md](SPATIAL_SQL.md). Other pairs throw. More than 800 edges throw.
- A buffer is a polygon. It is not a circular curve.
- Concave hull is points only.
- Ellipsoidal polygon area is not implemented. Vincenty throws instead of switching formulas when it does not converge.
- Geographic distance for a non-point is the minimum over vertices.
- CRS support is EPSG:4326, EPSG:3857, and the WGS84 UTM zones listed in [CRS.md](CRS.md). Datum grids are unavailable. UTM does not apply the Norway or Svalbard exceptions.
- GeoPackage, shapefile, KML, GPX, and FlatGeobuf are not readers or writers.
- `sqlite_plus_geo/io.dart` needs `dart:io`. Flutter web should pass a byte stream to `importGeoJsonStream`.
- `geoComputeIsolated` copies EWKB to another isolate and back. No speedup was measured.
- Crash behaviour is the sqlite_plus savepoint and image behaviour. A killed process was not simulated beyond rollback and `exportImage`.
- macOS, Windows, Android, iOS, and a browser were not launched for this package.
