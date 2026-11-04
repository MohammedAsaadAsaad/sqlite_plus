# Geodesy

`GeoGeodesy` accepts SRID 0 or 4326. Any other SRID throws. Longitude is X and latitude is Y, in degrees. A longitude outside [-180, 180] or a latitude outside [-90, 90] throws.

| Model | Formula | Unit |
|---|---|---|
| `GeodesicModel.planar` | Euclidean degrees | not metres |
| `GeodesicModel.sphere` | Haversine on radius 6371007.180918475 m | metres |
| `GeodesicModel.ellipsoid` | Vincenty inverse on WGS84 | metres |

WGS84 `a` is 6378137 m, `f` is 1/298.257223563, and `b` is 6356752.314245 m. One equatorial degree is `a * π / 180`, and the Vincenty result for that pair is within 0.01 m of that arc. The equator-to-pole distance is within 0.01 m of 10001965.729 m. Those two checks are in `test/geodesy/geodesy_test.dart`. They are not a centimetre claim for every pair.

Vincenty iterates at most 100 times and throws `GeoException` when it does not converge. The pair (0, 0) and (179.7, 0.5) must either throw or return more than 19,000,000 m. There is no silent haversine fallback.

`azimuth` is degrees clockwise from north. `ST_Azimuth` returns that angle in radians for SRID 0 or 4326. `destination` solves the direct problem and returns a point with SRID 4326 when the start SRID was 0.

`GeoGeodesy.length` sums each linestring or ring separately. A polygon hole is not connected to the shell by an extra segment. `geoSphericalArea` uses the authalic radius and subtracts holes. `ST_Area` is planar shoelace, so on SRID 4326 it is square degrees, not square metres. `ST_AreaSphere` is the spherical area. There is no ellipsoidal area function.

`ST_DistanceSphere` and `ST_DistanceSpheroid` accept points. `ST_DWithin` with a fourth argument of 1 or true is spheroidal metres and also accepts points only. The three-argument form is planar and accepts the other implemented geometry pairs.
