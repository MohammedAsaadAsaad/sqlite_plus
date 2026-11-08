# sqlite_plus_vec

Nearest neighbors for one float32 column. The module name is `vec0`. The query reads every stored row and returns the `k` closest.

![The query sits next to [1, 0], so that stored vector is the nearest.](doc/nearest.png)

```yaml
dependencies:
  sqlite_plus: ^0.1.13
  sqlite_plus_vec: ^0.1.6
```

## Distances

`DbVectorMetrics.l2` is Euclidean distance, the square root of the sum of squared coordinate differences. `DbVectorMetrics.cosine` is one minus the cosine similarity. Cosine distance sits from 0 to 2. Two zero vectors have distance 0. A zero vector beside a non-zero vector has distance 1. The metric name is compared without regard to case, so `'COSINE'` is `cosine`.

| Left | Right | Metric | Distance |
|---|---|---|---|
| `[0, 0]` | `[3, 4]` | `l2` | `5` |
| `[1, 0]` | `[1, 0]` | `cosine` | `0` |
| `[1, 0]` | `[0, 1]` | `cosine` | `1` |
| `[1, 0]` | `[-1, 0]` | `cosine` | `2` |
| `[0, 0]` | `[0, 0]` | `cosine` | `0` |
| `[0, 0]` | `[1, 0]` | `cosine` | `1` |

`vecDistance` is that function. Different lengths throw `vec0 dimension mismatch`. `hamming` throws `vec0: unknown distance metric: hamming`.

`encodeVec` writes little-endian float32. `decodeVec` reads it back. Dimensions are 1 to 4096, the same bounds as `DbVectorLimits`. An empty list, a list longer than 4096, and a non-finite coordinate are rejected. `decodeVec(encodeVec(const [0.5, -2, 0.25]))` is `[0.5, -2, 0.25]`.

## SQL

Register before `CREATE`. `SqlitePlusVec.register` accepts a `SqliteDatabase`, a `MutableSqliteDatabase`, or the connection's `SqlFunctionRegistry`. A second call keeps the module that is already registered.

```dart
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

final db = await openFileImage('points.db');
SqlitePlusVec.register(db);
await db.execute(
  'CREATE VIRTUAL TABLE items USING vec0(embedding float[2] distance_metric=l2)',
);
await db.execute(
  'INSERT INTO items(rowid, embedding) VALUES (1, ?), (2, ?), (3, ?)',
  [
    encodeVec(const [1, 0]),
    encodeVec(const [0, 1]),
    encodeVec(const [0.2, 0.1]),
  ],
);
final near = await db.query(
  'SELECT rowid, distance FROM items WHERE embedding MATCH ? AND k = 2',
  [encodeVec(const [0.9, 0.1])],
);
await File('points.db').writeAsBytes(db.exportImage(), flush: true);
```

`near` is row `1`, then row `3`. Row `1` is `[1, 0]`, the closer of the two to `[0.9, 0.1]`. Row `2` is `[0, 1]` and is farther, so `k = 2` leaves it out. `distance` is a `double`, and the first distance is smaller than the second.

The hidden columns are `distance` and `k`. The vector is column 0. `MATCH` without `k` throws `vec0: k is required`. `k = 0` throws `vec0: k is out of range`. In SQL, `k` is an integer from 1 to 100000. A query with no `MATCH` returns every row and leaves `distance` and `k` null.

Creating the table before `register` fails with `No such module: vec0`. `distance_metric=hamming` fails with `vec0: unknown distance metric`. `float[0]` is rejected. A blob whose length is not `dimensions * 4` can be inserted into the shadow table, and reading it throws `vec0 dimension mismatch`.

The bytes live in `items_vec`. `DROP TABLE items` drops that shadow. `BEGIN`, an insert, and `ROLLBACK` leave `count(*)` at 0. `exportImage` keeps the shadow rows. The next `openFileImage` needs `SqlitePlusVec.register` again before the next `MATCH` query. The virtual-table name in the schema is not enough. The module object lives on the connection.

`rankVec0` reads that shadow without a second copy of the table. Pass `rowIds` and only those rows are scored; an empty list reads nothing. There is no `k` cutoff, so a later filter cannot drop a neighbor that was never scored. The rows come back in pages of 512, ordered by ascending distance and then row id. Each page is a stopped rowid scan. `rejectZeroVectors: true` throws `vec0 zero vector` when every stored coordinate is zero. The default keeps the cosine rule: that vector has distance 1 from a non-zero query. A missing requested row throws `vec0 row is missing`. Reopening the image and calling `rankVec0` does not require `register`, because the function reads the ordinary shadow table. `MATCH` with `k` is a different query and still selects `k` before any predicate it does not consume.

## A mapped table

[`sqlite_plus_orm`](https://pub.dev/packages/sqlite_plus_orm) writes the `CREATE` statement and the `nearest` method. It does not import this package. `DbModules.vec0` is `'vec0'`. `DbVectorMetrics.l2` is `'l2'`. `@DbVector(2)` uses `l2` when `metric` is omitted. Another identifier can be written as a string. `vec0` checks it when the table is created.

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

The table has one `rowid` and one `List<double>`. `distance` and `k` are reserved names, so a field with either name is rejected. A vector on an ordinary table or on `fts5` is rejected. Dimensions outside 1 to 4096 are rejected. The list element is non-nullable `double`.

```dart
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final database = await openFileImage('points.db');
final connection = MutableDatabaseConnection(database, closeDatabase: true);
SqlitePlusVec.register(connection.database);
final context = DbContext(connection, generatedModel);
await context.migrations.ensureCreated();

final points = context.set(PointMapping.instance);
points.add(Point(embedding: const [1, 0]));
points.add(Point(embedding: const [0, 1]));
await context.saveChanges(); // 2
await File('points.db').writeAsBytes(database.exportImage(), flush: true);

final nearest = await points.query.nearest(const [0.9, 0.1], k: 1).single();
final again = await context.migrations.plan();
```

`ensureCreated` writes `CREATE VIRTUAL TABLE "Point" USING vec0("embedding" float[2] distance_metric=l2)`. `nearest.embedding` is `[1.0, 0.0]`. The query text is `"embedding" MATCH ? AND "k" = ?`, ordered by `distance`. `again` is empty.

`Codecs.vector(2)` checks the list before the write. `nearest(const [1], k: 1)` throws `OrmCodecException` because the length is not 2. `k: 0` throws `RangeError`. ORM `k` stops at `DbVectorLimits.maximumNeighbors`, which is 4096. The engine's SQL bound of 100000 stays available to a raw query.

A cosine table is the same class with `metric: DbVectorMetrics.cosine`. The created SQL then contains `distance_metric=cosine`.

## What the generator writes

[`sqlite_plus_generator`](https://pub.dev/packages/sqlite_plus_generator) reads `DbModules.vec0` and `@DbVector(2)`. The part contains `virtualModule: "vec0"`, `Codecs.vector(2)`, `vectorDimensions: 2`, `vectorMetric: "l2"`, and `nearest(List<double> vector, {int k = 10})`. The default `k` in that method is 10. It does not import `sqlite_plus_vec`.

```dart
final point = (await PointQuery(points.query)
        .nearest(const [0.9, 0.1], k: 1)
        .toList())
    .single;
```

`point.embedding[0]` is greater than `0.5`. That is the vector `[1, 0]`, which is closer to `[0.9, 0.1]` than `[0, 1]` is. Register `SqlitePlusVec` before `ensureCreated`.

## The runnable example

`packages/sqlite_plus_vec/example` saves `[1, 0]` and `[0, 1]`, then asks for one neighbor of `[0.9, 0.1]`.

```sh
cd packages/sqlite_plus_vec/example
dart run bin/main.dart
```

```text
1.0 | stable true
```

`1.0` is the first coordinate of the chosen vector, so the row is `[1, 0]`. `stable true` means a second `plan()` is empty.

## Where each piece lives

| You want | Package | You call |
|---|---|---|
| The shadow rows and the SQL engine | [`sqlite_plus`](https://pub.dev/packages/sqlite_plus) | `points.db`, then `MATCH` |
| `DbModules.vec0`, `@DbVector`, `nearest` | [`sqlite_plus_orm`](https://pub.dev/packages/sqlite_plus_orm) | `points.query.nearest` |
| The class turned into a part | [`sqlite_plus_generator`](https://pub.dev/packages/sqlite_plus_generator) | `dart run sqlite_plus_generator` |
| The distance, `rankVec0`, and the `vec0` module | this package | `SqlitePlusVec.register`, `rankVec0` |

## The packages on pub.dev

Each package is a complete library. Import only what you call. The links below are the package pages.

| Package | Version | Page |
|---|---|---|
| sqlite_plus | `^0.1.13` | <https://pub.dev/packages/sqlite_plus> |
| sqlite_plus_orm | `^0.1.12` | <https://pub.dev/packages/sqlite_plus_orm> |
| sqlite_plus_generator | `^0.1.12` | <https://pub.dev/packages/sqlite_plus_generator> |
| sqlite_plus_arabic | `^0.1.6` | <https://pub.dev/packages/sqlite_plus_arabic> |
| sqlite_plus_vec | `^0.1.6` | <https://pub.dev/packages/sqlite_plus_vec> |
| sqlite_plus_geo | `^0.1.5` | <https://pub.dev/packages/sqlite_plus_geo> |

### sqlite_plus

```yaml
dependencies:
  sqlite_plus: ^0.1.13
```

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

final db = await openDatabase('shelf.db');
await db.execute(
  'CREATE TABLE IF NOT EXISTS note (id INTEGER PRIMARY KEY, title TEXT)',
);
await db.insert('note', {'title': 'Kept Garden'});
final rows = await db.query(
  'note',
  columns: ['title'],
  where: 'title LIKE ?',
  whereArgs: ['%Garden%'],
);
```

The title is `Kept Garden`. A missing `shelf.db` is created. The next launch opens the same file. Integers come back as `BigInt`. There is no FFI and no native SQLite in this engine.

![The row is written to shelf.db, the handle closes, and the next open reads the same title.](doc/shelf-file.png)

### sqlite_plus_orm

```yaml
dependencies:
  sqlite_plus_orm: ^0.1.12
```

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity()
class Note {
  Note({this.id, required this.title, this.revision = 0});
  final BigInt? id;
  String title;
  @DbVersion()
  int revision;
}
```

`saveChanges` writes one transaction and bumps `revision`. A table with no `PRIMARY KEY` still maps. Its key is the SQLite row id:

```dart
@DbKey(generated: true)
final BigInt? rowid;
```

`plan()` adopts that row id and does not rebuild the table.

### sqlite_plus_generator

```yaml
dev_dependencies:
  sqlite_plus_generator: ^0.1.12
```

```sh
dart run sqlite_plus_generator
```

From the package root, that command writes a part for every public `@DbEntity` under `lib/`, plus `lib/sqlite_plus_migrations.g.dart`.

### sqlite_plus_arabic

```yaml
dependencies:
  sqlite_plus_arabic: ^0.1.6
```

```dart
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';

SqlitePlusArabic.register(db);
await db.execute(
  "CREATE VIRTUAL TABLE passage USING fts5(body, tokenize = 'arabic')",
);
```

`حديقة` and `الحديقة` share one token. `الله` stays `الله`. This is not the SQLite ICU Arabic tokenizer. Register before `CREATE`, and again after the image is reopened.

### sqlite_plus_vec

```yaml
dependencies:
  sqlite_plus_vec: ^0.1.6
```

```dart
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

SqlitePlusVec.register(db);
await db.execute(
  'CREATE VIRTUAL TABLE point USING vec0(embedding float[2] distance_metric=l2)',
);
```

`MATCH` with `k` scans every stored float32 vector. The file is not a sqlite-vec database.

### sqlite_plus_geo

```yaml
dependencies:
  sqlite_plus_geo: ^0.1.5
```

```dart
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';

final geo = GeoSession(db);
await geo.createSpatialTable(
  'facilities',
  geometryColumn: 'location',
  geometryType: GeoGeometryType.point,
  srid: 4326,
);
```

X is longitude and Y is latitude. `ST_SetSRID` only labels a geometry. `ST_Transform` moves a coordinate between EPSG:4326, EPSG:3857, and WGS84 UTM. A degree is not a metre. This is not an OGC, PostGIS, SpatiaLite, or GeoPackage certification.


An application that does not import this package does not load `vec0`. [`sqlite_plus`](https://pub.dev/packages/sqlite_plus) stores the rows in a shadow table. This package supplies the distance and the virtual table.

The scan compares every vector. It does not build an approximate index. A file written here is a sqlite_plus image with a shadow table named `<table>_vec`. A sqlite-vec database file is a different format.
