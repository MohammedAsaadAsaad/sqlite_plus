# Nearest notes

One in-memory `vec0` table. The mapping lives in `lib/nearest_notes.dart`. It uses [`sqlite_plus_orm`](../../sqlite_plus_orm) for the table and [`sqlite_plus_vec`](../) for the module. The engine underneath is [`sqlite_plus`](../../sqlite_plus).

`Point` has a generated `rowid` and `List<double> embedding`. The entity is `DbModules.vec0`. The column is `Codecs.vector(2)` with `DbVectorMetrics.l2`. The created SQL contains `float[2] distance_metric=l2`.

`runNearestNotes` does five steps:

1. The example writes `points.db` and reads that file back.
2. `SqlitePlusVec.register(connection.database)` installs `vec0` on that connection.
3. `ensureCreated` creates the virtual table and its shadow.
4. Two vectors are saved: `[1, 0]` and `[0, 1]`.
5. `nearest(const [0.9, 0.1], k: 1)` returns one row. A second `plan()` is empty.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

```text
1.0 | stable true
```

`1.0` is the first coordinate of the returned vector. `[0.9, 0.1]` is closer to `[1, 0]` than to `[0, 1]`, so the row is the first saved vector. The scan compares both stored rows. `stable true` means the migration plan after the save is empty.

The package README walks through `k = 2`, cosine distance, and the same query from SQL and from a generated `nearest` method. The image is a sqlite_plus database. A sqlite-vec file is a different format.
