# sqlite_plus_vec

Nearest neighbors for one float32 vector column. The query scans every stored row.

```yaml
dependencies:
  sqlite_plus_vec: ^0.1.0
```

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

final db = await openInMemory();
SqlitePlusVec.register(db);
await db.execute(
  'CREATE VIRTUAL TABLE items USING vec0(embedding float[2] distance_metric=l2)',
);
await db.execute(
  'INSERT INTO items(rowid, embedding) VALUES (1, ?), (2, ?)',
  [encodeVec(const [1, 0]), encodeVec(const [0, 1])],
);
final near = await db.query(
  'SELECT rowid, distance FROM items WHERE embedding MATCH ? AND k = 1',
  [encodeVec(const [0.9, 0.1])],
);
```

`near` is row `1`. `DbVectorMetrics.l2` is Euclidean distance. `DbVectorMetrics.cosine` is one minus the cosine similarity, from 0 to 2. Two zero vectors have distance 0. A zero vector beside a non-zero vector has distance 1. `k` is required with `MATCH` and is an integer from 1 to 100000. A query without `MATCH` returns every row and leaves `distance` null.

`encodeVec` writes little-endian float32. Dimensions are 1 to 4096. A non-finite coordinate is rejected. The rows live in the shadow table `items_vec`. This module does not read or write sqlite-vec files, and it does not build an approximate index.

The ORM stores the same shape. Register the module before `ensureCreated` or `nearest`.

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

@DbEntity(module: DbModules.vec0)
class Point {
  Point({this.rowid, required this.embedding});
  @DbKey(generated: true)
  final BigInt? rowid;
  @DbVector(2, metric: DbVectorMetrics.l2)
  final List<double> embedding;
}
```

```dart
SqlitePlusVec.register(connection.database);
final nearest = await points.query.nearest(const [0.9, 0.1], k: 1).toList();
```

`@DbVector(2)` uses `l2` when `metric` is omitted. Another identifier can be written as a string. `vec0` rejects a metric it does not implement when the table is created. A second `register` keeps the existing module. Reopening an image needs another `register` on that connection.

[`sqlite_plus`](../sqlite_plus) stores the shadow rows. [`sqlite_plus_orm`](../sqlite_plus_orm) writes `float[N]` and `distance_metric`, and `nearest` writes `MATCH` and `k`. [`sqlite_plus_generator`](../sqlite_plus_generator) emits `Codecs.vector` and `nearest`. The generated part does not import this package.
