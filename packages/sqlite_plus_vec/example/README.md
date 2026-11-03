# Nearest notes

One in-memory `vec0` table. The scan compares every stored vector.

| Step | Call | Result |
|---|---|---|
| Register | `SqlitePlusVec.register` | Module `vec0` |
| Create | `ensureCreated` with `DbModules.vec0` | `float[2] distance_metric=l2` |
| Save | `[1, 0]` and `[0, 1]` | two rows |
| Query | `nearest([0.9, 0.1], k: 1)` | the first vector |

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

```text
1.0 | stable true
```

This table is not a sqlite-vec file, and the scan is not an approximate index.
