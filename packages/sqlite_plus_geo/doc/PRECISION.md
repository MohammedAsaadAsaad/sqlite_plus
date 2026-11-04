# Precision

Orientation uses exact dyadic arithmetic. `geoOrientation` reads the IEEE bits of each double, builds `significand * 2^exponent` with `BigInt`, and returns the sign of the cross product. It does not use an epsilon. A positive value is counter-clockwise.

Segment intersection uses that orientation test. A constructed intersection point is then an IEEE double. Overlay, buffer, and simplify continue in floating point after that. The property test with seed `20261104` checks that, for convex hulls of random points, `area(union(A,B))` matches `area(A) + area(B) - area(intersection)` within `1e-3`, and that `difference(A,A)` is empty.

Nearly coincident points stay distinct until an operation explicitly snaps them. `geoSnap` moves a vertex onto a reference vertex within the tolerance and throws if the vertex product would exceed `20000 * 20000`. There is no global epsilon.

NaN and infinity are rejected at construction and by the parsers. WKB writes the finite bits it was given. WKT writes `double.toString()`.

The R-tree widens boxes to enclosing float32 values. That changes the index key, not the stored EWKB.

Geographic distances document their own metre tolerances in [GEODESY.md](GEODESY.md). Planar area on a geographic SRID is not converted to metres.
