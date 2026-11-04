# sqlite_plus_geo examples

`dart run bin/main.dart` opens an in-memory `sqlite_plus` database and runs four demos:

1. Facilities within 5 km of a point, ordered by spherical distance.
2. A GeoJSON feature collection imported and queried offline.
3. The administrative polygon that contains a coordinate.
4. `ST_Intersection` of two parcel squares.

The program prints:

```text
Clinic | North | 2 | 2.0 | true
```

A map widget is not a dependency. Convert a stored point with `point.toMapPosition()`. Pass `longitude` and `latitude` to the widget's own point type. X is already longitude.
