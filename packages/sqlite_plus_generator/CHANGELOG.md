# Changelog

## 0.1.5

Depends on `sqlite_plus_orm` 0.1.4.

- `module: DbModules.fts5` and `module: 'fts5'` both emit `search`. `tokenizer: DbTokenizers.porter` and `tokenizer: 'arabic'` both emit `tokenize = '...'`.
- `module: DbModules.vec0` with `@DbVector(n, metric: DbVectorMetrics.cosine)` emits `Codecs.vector(n)`, `vectorMetric: "cosine"`, and `nearest`.
- The generated part does not import `sqlite_plus_arabic` or `sqlite_plus_vec`.
- An unknown module, a tokenizer off FTS5, a vector off `vec0`, a dimension outside 1 to 4096, and a column named `distance` or `k` on `vec0` fail before a file is written.

## 0.1.4

Depends on `sqlite_plus_orm` 0.1.3. `sqlite_plus` and `sqlite_plus_orm` stay `0.1.3`.

From the package root, one command generates every public `@DbEntity` class under `lib/`:

```sh
dart run sqlite_plus_generator
```

`lib/book.dart` does not need a `part` directive. The command adds it.

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity()
class Book {
  Book({this.id, required this.title});
  final BigInt? id;
  final String title;
}
```

The same run writes `lib/book.orm.g.dart` and `lib/sqlite_plus_migrations.g.dart`. A class that only has an `id` field is not included. The app opens one context for the whole package:

```dart
import 'package:your_app/book.dart' hide generatedModel;
import 'package:your_app/note.dart' hide generatedModel;
import 'package:your_app/sqlite_plus_migrations.g.dart';

final context = DbContext(connection, generatedModel);
await context.migrations.ensureCreated();
final plan = await context.migrations.plan();
await context.migrations.applySafe(plan);
```

`ensureCreated` creates the tables on an empty database. `plan` then `applySafe` adds a new nullable column. A rename or another destructive change stays a reviewed plan. The command does not open a database.

A later run prints what it found and skips a part whose source stamp still matches:

```text
Found Book in lib/book.dart. Already generated. Leaving lib/book.orm.g.dart unchanged.
Found Note in lib/note.dart.
Generating lib/note.orm.g.dart.
Created lib/note.orm.g.dart.

Summary for the package
Unchanged: lib/book.orm.g.dart (Book)
Created: lib/note.orm.g.dart (Note)
Updated: lib/sqlite_plus_migrations.g.dart (Book, Note)
```

`Created` is a new file, `Updated` is a changed class, and `Unchanged` was not generated again. `--check` reports `Stale` and writes nothing. One library is still:

```sh
dart run sqlite_plus_generator --input lib/models.dart
```

That form still accepts a conventional `id` class. A `@DbReference` target has to be a `@DbEntity` class in the same library.

## 0.1.3

Depends on `sqlite_plus_orm` 0.1.3. pub.dev already serves `0.1.2`.

- `@DbScalar()` on an instance method or getter becomes `row.twice()` with no parameters. The part registers `table_method` and passes the mapped fields that body reads.

## 0.1.2

Depends on `sqlite_plus_orm` 0.1.2. The page uses the Linux release-build sample and the new logo.

## 0.1.1

The package page leads with the five classes and the generated filter, JSON path, search, and bounds. Depends on `sqlite_plus_orm` 0.1.1.

## 0.1.0

Release number. Depends on `sqlite_plus_orm` 0.1.0.

## 0.0.3

Release number. Depends on `sqlite_plus_orm` 0.0.3.

## 0.0.2

Published release. Depends on `sqlite_plus_orm` 0.0.2, `analyzer` 14, and `dart_style` 3.

## 0.0.1-dev.1

First pre-release.

- Generates columns, codecs, keys, revisions, and relationships from ordinary classes.
- Generates JSON `path`, FTS `search`, and R-tree `bounds`.
- The library example ships with the checked-in part.
