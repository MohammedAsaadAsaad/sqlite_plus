![sqlite_plus](doc/logo.png)

# sqlite_plus

SQL, JSON, full-text search, and R-tree in Dart. No FFI, no native SQLite, and no WASM in the production runtime.

```yaml
dependencies:
  sqlite_plus: ^0.1.11
```

## A table, a row, a query

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

final db = await openDatabase(
  'shelf.db',
  version: 1,
  onCreate: (db, version) async {
    await db.execute(
      'CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT, body TEXT)',
    );
  },
);
await db.insert('note', {
  'title': 'Kept Garden',
  'body': 'a garden kept in the margin',
});
final rows = await db.query(
  'note',
  columns: ['title'],
  where: 'title LIKE ?',
  whereArgs: ['%Garden%'],
  orderBy: 'title',
);
```

`rows` is one map whose title is `Kept Garden`. A missing `shelf.db` is created, and so is an empty `-journal`. An existing file is opened and left in place. Integers come back as `BigInt`. An `int` argument is stored as an integer. `insert`, `query`, `update`, `delete`, `transaction`, and `batch` are on this same connection. SQL still runs through `execute` and `rawQuery`.

![The row is written to shelf.db, the handle closes, and the next open reads the same title.](doc/shelf-file.png)

## A JSON card

```dart
await db.execute(
  'CREATE TABLE book (id INTEGER PRIMARY KEY, card TEXT NOT NULL)',
);
await db.execute(
  'INSERT INTO book(card) VALUES (json_object(?, ?, ?, ?))',
  ['title', 'Kept Garden', 'pages', 320],
);
final pages = await db.rawQuery(
  'SELECT json_extract(card, ?) FROM book WHERE json_extract(card, ?) = ?',
  [r'$.pages', r'$.title', 'Kept Garden'],
);
```

`pages` is `320`. `db` is the `shelf.db` connection from the first example.

## A word in the page

```dart
await db.execute('CREATE VIRTUAL TABLE book_text USING fts5(title, body)');
await db.execute(
  'INSERT INTO book_text(title, body) VALUES (?, ?)',
  ['Kept Garden', 'a garden kept in the margin'],
);
final hit = await db.rawQuery(
  "SELECT highlight(book_text, 1, '[', ']') FROM book_text WHERE book_text MATCH ?",
  ['kept'],
);
```

`hit` is `a garden [kept] in the margin`. This is the engine's own FTS5 table.

## A box on the shelf

```dart
await db.execute(
  'CREATE VIRTUAL TABLE shelf USING rtree(id, minX, maxX, minY, maxY)',
);
await db.execute('INSERT INTO shelf VALUES (1, 0, 1, 0, 1)');
final place = await db.rawQuery(
  'SELECT id FROM shelf WHERE minX <= 1 AND maxX >= 0 AND minY <= 1 AND maxY >= 0',
);
```

`place` is shelf `1`.

## A function, a rollback, a reopen

```dart
import 'package:sqlite_plus/sqlite_plus.dart';

final memory = await openInMemory();
memory.functions.registerScalar(
  'twice',
  1,
  (args) => args.single == null ? null : (args.single as BigInt) * BigInt.two,
);
final doubled = await memory.query('SELECT twice(?)', [21]);

await memory.execute(
  'CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT, body TEXT)',
);
await memory.execute('BEGIN');
await memory.execute(
  'INSERT INTO note(title, body) VALUES (?, ?)',
  ['Rolled Back', 'gone'],
);
await memory.execute('ROLLBACK');

await memory.execute('PRAGMA user_version = 7');
final again = await MutableSqliteDatabase.fromImage(memory.exportImage());
```

`doubled` is `42`. The rolled-back row is gone. `again` opens the same image at `user_version` 7. Scalar functions and `exportImage` belong to this in-memory connection. The file opened above stays on disk.

## A file

`openDatabase` needs `dart:io`. It writes a missing database as an empty image and a missing `-journal` as an empty file. An existing database file is not replaced. `version` runs `onCreate`, `onUpgrade`, or `onDowngrade` and stores that number. `insert`, `query`, `update`, `delete`, `transaction`, and `batch` use that connection. `query` names a table. `rawQuery` runs SQL and returns maps. `directoryEntriesDurable: false` writes nothing and throws. That flag is a caller attestation, not a power-loss result. `wal: true` does not create a `-wal` file. A second open of the same path fails while the first owner is open.

## SQLCipher 4

```dart
final created = await SqlCipherDatabase.create('secret');
await created.database.execute('CREATE TABLE note (title TEXT)');
await created.database.execute(
  'INSERT INTO note(title) VALUES (?)',
  ['Kept Garden'],
);
final file = created.encryptedImage();

final opened = await SqlCipherDatabase.open(file, 'secret');
final title = await opened.database.query('SELECT title FROM note');
```

`file` is a SQLCipher 4 database: AES-256-CBC, HMAC-SHA512, and PBKDF2-HMAC-SHA512 for 256000 iterations. The salt is the first 16 bytes. Each page keeps an 80-byte reserve. `opened.database.exportImage()` is the decrypted SQLite image. `saveSqlCipher` writes the encrypted file in one pass. A file opens when the passphrase and the iteration count match the writer. Pass the same `iterations` value on both sides when it is not 256000. The codec is pure Dart, through `pointycastle`. An ordinary `openInMemory` or `openDatabase` does not call it.

## SQL

| You write | You get |
|---|---|
| Joins | `INNER` `LEFT` `RIGHT` `FULL` `CROSS`, `ON`, `USING` |
| Shape | Subqueries, `EXISTS`, `IN`, `UNION`, `INTERSECT`, `EXCEPT`, CTEs, `GROUP BY`, `HAVING` |
| Windows | `ROW_NUMBER` `RANK` `DENSE_RANK` `LAG` `LEAD` `FIRST_VALUE` `LAST_VALUE` `NTH_VALUE` |
| Writes | `INSERT` `UPDATE` `DELETE`, `ON CONFLICT`, `RETURNING`, `BEGIN` `COMMIT` `ROLLBACK`, savepoints |
| Schema | Tables, indexes, views, triggers, `ALTER TABLE`, `CHECK`, `STRICT`, foreign keys, generated columns |
| JSON | `json` `jsonb` `json_pretty` `json_extract` `json_object` `json_set` `json_patch`, `->` `->>` |
| Search | FTS5 and contentless FTS4 `MATCH`, `highlight` `snippet` `bm25`, R-tree, geopoly |
| Your code | `registerScalar`, `registerAggregate`, `createCollation`, `tokenizers.register` |

`registerScalar` stays on that connection. `deterministic: true` allows it inside a schema expression. `registerAggregate` builds a fresh aggregate per group. `createCollation` sits beside `BINARY`, `NOCASE`, and `RTRIM`. `tokenizers.register` adds an FTS tokenizer name. The built-in names `unicode61`, `porter`, `trigram`, `ascii`, and `simple` stay fixed.

## Speed

1,000 rows on Linux, release build. The same SQL on both engines, and every checksum matched. Each bar is that row's measured time.

![Memory, 1,000 rows. Bar length is measured time.](doc/bench-time.png)

| Operation | native | sqlite_plus | faster |
|---|---:|---:|---:|
| Separate insert | 1.896 s | 7.5 ms | 253× |
| Transaction insert | 1.841 s | 7.0 ms | 263× |
| Separate update | 1.853 s | 20.1 ms | 92× |
| Bulk update | 1.8 ms | 71 µs | 25× |
| Search | 1.864 s | 17.4 ms | 107× |
| Point lookup | 1.995 s | 25.4 ms | 79× |
| VACUUM | 2.2 ms | 77 µs | 29× |
| Separate delete | 1.777 s | 13.2 ms | 135× |
| Delete all | 1.4 ms | 159 µs | 8.8× |

On a file, search was 142×, a point lookup 104×, and `VACUUM` 175×.

![File, 1,000 rows. Bar length is measured time.](doc/bench-file.png)

| Operation | native | sqlite_plus | faster |
|---|---:|---:|---:|
| Separate insert | 5.319 s | 1.523 s | 3.5× |
| Transaction insert | 1.883 s | 181.5 ms | 10× |
| Separate update | 5.452 s | 1.667 s | 3.3× |
| Bulk update | 4.5 ms | 1.4 ms | 3.2× |
| Search | 2.280 s | 16.1 ms | 142× |
| Point lookup | 1.801 s | 17.4 ms | 104× |
| VACUUM | 6.3 ms | 36 µs | 175× |
| Separate delete | 5.207 s | 1.749 s | 3.0× |
| Delete all | 4.5 ms | 1.1 ms | 4.1× |

The file size is taken before close, so it still includes the redo.

## A page of search

Two or more documents share FTS5 leaves. A query of whole terms reads the leaves that contain those terms. One document keeps the older leaf.

The catalog stores 10,000 Arabic names and 10,000 English names and loads 20 at a time. On one arm64 phone, catalog release 0.5.2, `بسكويت` read `20 of 493 matches · 47.236 ms`.

![Page time for the Arabic query before and after packed leaves.](doc/search-compare.png)

![Catalog on one arm64 phone. Twenty of 493 matches in 47.236 ms.](doc/catalog-phone.jpg)

On Linux x64, AOT, that page took 26.967 ms, then 20.819 ms, and 25.663 ms at offset 320. `biscuit` took 19.717 ms, 25.481 ms, and 25.621 ms. Before packing, the same Linux process took 405 ms and then 359 ms, and the previous phone build showed 472.000 ms. [`sqlite_plus_search`](https://pub.dev/packages/sqlite_plus_search) is the index and the shelf filter on top of this engine.

## The packages on pub.dev

Each package is a complete library. Import only what you call. The links below are the package pages.

| Package | Version | Page |
|---|---|---|
| sqlite_plus | `^0.1.11` | <https://pub.dev/packages/sqlite_plus> |
| sqlite_plus_orm | `^0.1.9` | <https://pub.dev/packages/sqlite_plus_orm> |
| sqlite_plus_generator | `^0.1.9` | <https://pub.dev/packages/sqlite_plus_generator> |
| sqlite_plus_arabic | `^0.1.3` | <https://pub.dev/packages/sqlite_plus_arabic> |
| sqlite_plus_vec | `^0.1.3` | <https://pub.dev/packages/sqlite_plus_vec> |
| sqlite_plus_geo | `^0.1.2` | <https://pub.dev/packages/sqlite_plus_geo> |

### sqlite_plus

```yaml
dependencies:
  sqlite_plus: ^0.1.11
```

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

final db = await openDatabase(
  'shelf.db',
  version: 1,
  onCreate: (db, version) async {
    await db.execute(
      'CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT)',
    );
  },
);
await db.insert('note', {'title': 'Kept Garden'});
final rows = await db.query(
  'note',
  where: 'title LIKE ?',
  whereArgs: ['%Garden%'],
);
```

The title is `Kept Garden`. A missing `shelf.db` is created. Integers come back as `BigInt`. There is no FFI and no native SQLite in this engine.

![The row is written to shelf.db, the handle closes, and the next open reads the same title.](doc/shelf-file.png)

### sqlite_plus_orm

```yaml
dependencies:
  sqlite_plus_orm: ^0.1.9
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
  sqlite_plus_generator: ^0.1.9
```

```sh
dart run sqlite_plus_generator
```

From the package root, that command writes a part for every public `@DbEntity` under `lib/`, plus `lib/sqlite_plus_migrations.g.dart`.

### sqlite_plus_arabic

```yaml
dependencies:
  sqlite_plus_arabic: ^0.1.3
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
  sqlite_plus_vec: ^0.1.3
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
  sqlite_plus_geo: ^0.1.2
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

## Arabic search and vectors

[`sqlite_plus_arabic`](https://pub.dev/packages/sqlite_plus_arabic) registers the tokenizer `arabic`. [`sqlite_plus_vec`](https://pub.dev/packages/sqlite_plus_vec) registers the module `vec0`. Both stay out of an application that does not import them. Register each one before `CREATE`, and register it again after `fromImage`, because the registry belongs to the connection.

```dart
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

SqlitePlusArabic.register(db);
await db.execute(
  "CREATE VIRTUAL TABLE docs USING fts5(body, tokenize = 'arabic')",
);
await db.execute(
  'INSERT INTO docs(body) VALUES (?), (?)',
  ['في الحديقة', 'سيارة'],
);
final garden = await db.query(
  "SELECT body FROM docs WHERE docs MATCH 'حديقة'",
);

SqlitePlusVec.register(db);
await db.execute(
  'CREATE VIRTUAL TABLE items USING vec0(embedding float[2] distance_metric=l2)',
);
await db.execute(
  'INSERT INTO items(rowid, embedding) VALUES (1, ?), (2, ?)',
  [encodeVec(const [1, 0]), encodeVec(const [0, 1])],
);
final near = await db.query(
  'SELECT rowid FROM items WHERE embedding MATCH ? AND k = 1',
  [encodeVec(const [0.9, 0.1])],
);
```

`garden` is `في الحديقة`. `حديقة`, `الحديقة`, and `بالحديقة` share one token. `MATCH 'كتاب'` on those two rows is empty. `الله` stays `الله`. The stemmer removes one prefix and one suffix when three letters remain. SQLite ICU Arabic is a different tokenizer. The package page lists every fold.

`near` is row `1`. That row holds `[1, 0]`, which is closer to `[0.9, 0.1]` than `[0, 1]` is. `k` is required with `MATCH`. The scan reads every stored vector. The bytes live in the shadow table `items_vec`. A sqlite-vec file is a different format. `l2` is Euclidean distance. `cosine` runs from 0 to 2.

`tokenizers.register` is the same hook the Arabic package uses. A built-in name such as `unicode61` cannot be replaced. `virtualTables.register` is the hook `vec0` uses. A module can set `storesRows` and name its shadow columns. The engine then writes `INSERT`, `UPDATE`, and `DELETE` to that shadow.

[`sqlite_plus_orm`](https://pub.dev/packages/sqlite_plus_orm) turns the same two shapes into `search` and `nearest`. The constants are `DbModules.fts5`, `ArabicTokenizers.arabic`, `DbModules.vec0`, and `DbVectorMetrics.l2`. Each constant is a `String`, so `'fts5'` and `'arabic'` are the same text written by hand. [`sqlite_plus_generator`](https://pub.dev/packages/sqlite_plus_generator) emits those strings. The generated part does not import the two packages. The application still calls `register`.

## Packages built on this engine

| Package | What the application gets |
|---|---|
| [`sqlite_plus_orm`](https://pub.dev/packages/sqlite_plus_orm) | Objects, revisions, a typed JSON document, and reviewed migrations |
| [`sqlite_plus_generator`](https://pub.dev/packages/sqlite_plus_generator) | The mapping, `filter`, and `row.card.path` from the class |
| [`sqlite_plus_arabic`](https://pub.dev/packages/sqlite_plus_arabic) | The FTS5 tokenizer `arabic` for a reading note written in Arabic |
| [`sqlite_plus_vec`](https://pub.dev/packages/sqlite_plus_vec) | `vec0`, so a note can be found by the nearest embedding |

An application loads a package when it imports it. Arabic and vec stay out of a project that only stores rows.

```yaml
dependencies:
  sqlite_plus: ^0.1.9
  sqlite_plus_orm: ^0.1.9
  sqlite_plus_arabic: ^0.1.3
  sqlite_plus_vec: ^0.1.3

dev_dependencies:
  sqlite_plus_generator: ^0.1.9
```

### A reading card

[`sqlite_plus_orm`](https://pub.dev/packages/sqlite_plus_orm) keeps one object in a `TEXT` column. `@DbDocument()` calls `toJson` on save and `fromJson` on the rows a query returns. The filter stays SQL: `json_extract` with a bound path. The other rows stay stored text.

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity(table: 'notes')
class Note {
  Note({this.id, required this.card, this.revision = 0});

  final BigInt? id;
  @DbDocument()
  Card card;
  @DbVersion()
  int revision;
}

class Card {
  Card({required this.title, required this.pages});

  final String title;
  final int pages;

  Map<String, Object?> toJson() => {'title': title, 'pages': pages};

  factory Card.fromJson(Map<String, Object?> json) => Card(
    title: json['title']! as String,
    pages: json['pages']! as int,
  );
}
```

```dart
final notes = context.set(NoteMapping.instance);
notes.add(Note(card: Card(title: 'Kept Garden', pages: 320)));
notes.add(Note(card: Card(title: 'Other Atlas', pages: 40)));
await context.saveChanges();
final kept = await notes.query
    .filter((row) => row.card.path(r'$.title').equalTo('Kept Garden'))
    .single();
```

`kept.card.pages` is 320. The SQL is `json_extract("card", ?) = ?`, and the parameters are `$.title` and `Kept Garden`. `Other Atlas` is not decoded. A `String` column still uses `@DbJson`.

```dart
kept.card = Card(title: 'Kept Garden', pages: 321);
await context.saveChanges();
final revised = await notes.query
    .filter((row) => row.card.path(r'$.title').equalTo('Kept Garden'))
    .single();
```

`revised.card.pages` is 321 and `revised.revision` is 1. The other note stays at revision 0. The next read shows that revision, because a final `id` is replaced when the store writes the key back.

A method on the class is a query too. `twice` reads `revision`. `upper` is this engine.

```dart
@DbScalar()
BigInt? twice() => revision * BigInt.two;

final large = await books.query
    .selectWhere((row) => (row.twice() > 20) | row.title.upper().equalTo('WEST'))
    .toList();
```

### The generator writes the mapping

[`sqlite_plus_generator`](https://pub.dev/packages/sqlite_plus_generator) reads the class and writes the part. From the package root:

```sh
dart run sqlite_plus_generator
```

For the card above the part contains `DocumentField(NoteColumns.card)` and, on that column, `Codecs.document(Card.fromJson, (value) => value.toJson())`. `row.card.path` is that field. The part does not import `sqlite_plus_arabic` or `sqlite_plus_vec`. One library is still `dart run sqlite_plus_generator --input lib/models.dart`. The same run writes `lib/sqlite_plus_migrations.g.dart` for `ensureCreated`.

### Arabic words in the note

[`sqlite_plus_arabic`](https://pub.dev/packages/sqlite_plus_arabic) registers the tokenizer `arabic`. The SQL sample above inserts `في الحديقة` and `سيارة`, then `MATCH 'حديقة'` returns `في الحديقة`. `حديقة`, `الحديقة`, and `بالحديقة` share one token. `MATCH 'كتاب'` on those two rows is empty. `الله` stays `الله`. The stemmer removes one prefix and one suffix when three letters remain. This is not the SQLite ICU Arabic tokenizer.

The same table from the ORM:

```dart
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';

@DbEntity(module: DbModules.fts5, tokenizer: ArabicTokenizers.arabic)
class Passage {
  Passage({this.rowid, required this.body});
  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}

SqlitePlusArabic.register(connection.database);
await context.migrations.ensureCreated();
passages.add(Passage(body: 'في الحديقة'));
passages.add(Passage(body: 'سيارة'));
await context.saveChanges(); // 2
final garden = await passages.query.search('الحديقة').single();
```

`garden.body` is `في الحديقة`. The created SQL contains `tokenize = 'arabic'`. Register before `ensureCreated`, and register again after `fromImage`. Without that call, create fails with `no such tokenizer: arabic`.

### The nearest note

[`sqlite_plus_vec`](https://pub.dev/packages/sqlite_plus_vec) registers `vec0`. The SQL sample above stores `[1, 0]` and `[0, 1]`, and `k = 1` against `[0.9, 0.1]` returns row 1. The scan reads every stored vector. The bytes live in the shadow table `items_vec`. A sqlite-vec file is a different format.

```dart
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

@DbEntity(module: DbModules.vec0)
class Neighbor {
  Neighbor({this.rowid, required this.embedding});
  @DbKey(generated: true)
  final BigInt? rowid;
  @DbVector(2, metric: DbVectorMetrics.l2)
  final List<double> embedding;
}

SqlitePlusVec.register(connection.database);
await context.migrations.ensureCreated();
neighbors.add(Neighbor(embedding: const [1, 0]));
neighbors.add(Neighbor(embedding: const [0, 1]));
await context.saveChanges(); // 2
final near = await neighbors.query.nearest(const [0.9, 0.1], k: 1).single();
```

`near.embedding` is `[1.0, 0.0]`. `[0.9, 0.1]` is closer to that row than to `[0, 1]`. The created SQL contains `float[2] distance_metric=l2`. `l2` is Euclidean distance. `cosine` runs from 0 to 2. `k` is required. Register before `ensureCreated`, and register again after the image is reopened.

`openInMemory` is `MutableSqliteDatabase.create`. `exportImage` is the byte image a file can hold. `openBrowserStorage` reports `canRead`, `canWrite`, `durabilityPromised`, and `placement`.

Compared with pinned SQLite 3.53.1: constant `EXPLAIN` arithmetic, a constant `WHERE`, one table scan, a constant subquery, an integer-primary-key scan, `WITHOUT ROWID`, a virtual generated column, a typed `INSERT`, and a multi-row `VALUES` insert. An integer-primary-key insert and a join of two subqueries still have no bytecode. This is not a VDBE. Contentless FTS4 returns the pinned `MATCH` row and stores no content table. File `journal_mode` `wal`, `persist`, and `truncate` follow the pinned header and journal bytes. This is not a multi-frame WAL. `incremental_vacuum` moves a live end page before truncating. ICU collations are absent. Correlated `json_each` matches the pinned CLI, including `json_each(docs.label) RIGHT JOIN docs`, which returns 0 rows. Set `doubleQuotedStrings` to treat an unresolved double-quoted identifier as a string. The default is off. The comparison is `db_browser_b3_dqs_test.dart`. Unquoted `a.title` beside a column named `a.title` returns the `title` column.
