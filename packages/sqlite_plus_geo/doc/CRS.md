# Coordinate reference systems

`geoCrs` knows these definitions. All of them use the WGS84 datum. No other datum is transformed.

| SRID | Name | Axes | Unit |
|---|---|---|---|
| 4326 | WGS 84 | longitude, latitude | degree |
| 3857 | WGS 84 / Pseudo-Mercator | easting, northing | metre |
| 32601–32660 | WGS 84 / UTM zone nN | easting, northing | metre |
| 32701–32760 | WGS 84 / UTM zone nS | easting, northing | metre |

Web Mercator uses sphere radius 6378137 m. Latitude is limited to ±85.05112877980659. `x = λ * R` and `y = R * ln(tan(π/4 + φ/2))` with angles in radians. Longitude 1°, latitude 0 projects to about 111319.49079327357 m and inverts within `1e-8` degrees.

UTM uses scale 0.9996, false easting 500000 m, and false northing 0 in the north or 10000000 m in the south. The central meridian is `(zone - 1) * 6 - 180 + 3`. Longitude 33°, latitude 0 is zone 36 and projects to easting 500000 m. Norway and Svalbard zone exceptions are not applied. The series is a Snyder transverse Mercator, checked by the round trip in `test/crs/crs_test.dart` to `1e-6` degrees on that central-meridian point. That is not a national-grid certification.

`ST_SetSRID` assigns metadata. `ST_Transform` changes coordinates. A source SRID of 0 throws. An unknown SRID throws `CRS <n> is not available`. A datum shift that needs a grid throws `datum transformation is unavailable` and is not approximated.

This is not a complete EPSG database.
