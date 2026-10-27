# sqlite_plus_generator

مولّد خرائط لـ sqlite_plus_orm: يقرأ أصناف Dart ويكتب `path` لـ JSON، و`search` لـ FTS5، و`bounds` لـ R-tree. التطبيق الناتج يستدعي ORM من غير نص SQL.

A development-time generator for `sqlite_plus_orm`. It reads Dart classes and writes runtime mappings. The generated application does not depend on the analyzer.

Version `0.0.1-dev.1` is a pre-release. It is prepared for pub.dev and is not published. Until the packages are published:

```yaml
dev_dependencies:
  sqlite_plus_generator:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus_generator
      ref: main
```

```sh
dart run sqlite_plus_generator --input lib/models.dart
dart run sqlite_plus_generator --input lib/models.dart --check
```

## Generated library

`example/models.dart` declares a customer, a purchase, a JSON note, an FTS5 article, and an R-tree place. `example/library_app.dart` saves three purchases, two notes, two articles, and two places through `generatedModel`. The filter keeps totals above 20 and orders them. The JSON path, FTS search, and R-tree bounds each return one row:

```dart
final rows = await purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
final note = (await NoteQuery(notes.query)
        .filter((row) => row.path(r'$.title').equalTo('kept'))
        .toList())
    .single;
final article =
    (await ArticleQuery(articles.query).search('kept').toList()).single;
```

From this package:

```sh
dart run example/library_app.dart
```

The test expects customer `Ada`, totals `22.5` then `30.0`, note `{"title":"kept"}`, article `alpha kept`, place id `1` of two stored places, and an empty second migration plan. `example/models.dart` passes `--check`.

## Conventions

The source imports sqlite_plus_orm and declares `part 'models.orm.g.dart';`.
Use repeated `--class Name` options to select classes, and `--output` for a
matching alternative part path. The repository example is reproducible with:

```sh
dart run bin/sqlite_plus_generator.dart --input example/models.dart --check
```

Conventions select concrete public classes with `id`/`<ClassName>Id`. SQL names
default to exact Dart names. Optional DbEntity, DbColumn, DbIgnore, DbKey,
DbVersion, DbJson and DbReference annotations override conventions, using
resolved type identity and supporting import prefixes. DbReference.column names
a target Dart property; absent that, the target needs one primary key.
`@DbJson()` on one String field emits `path`. `@DbEntity(module: 'fts5')`
needs a `rowid` key and String content columns, and emits `search`.
`@DbEntity(module: 'rtree')` needs an integer key first and double `minX`,
`maxX`, `minY`, and `maxY`, and emits `bounds`.

Supported fields are int, BigInt, double, bool, String, Uint8List, DateTime and
nullable aliases of those types. Constructors must map persisted state; mutable
fields can be assigned after construction. Immutable generated keys reconstruct
the entry value after save. Nullable assigned keys still require a nonnull value
when an entity is tracked. Composite keys are supported; composite relationships,
custom codecs, indexes and unsupported model shapes use manual metadata.

Generic/inherited/mixin storage, unsupported/custom/collection types, ambiguous
constructors and unmappable final state produce located actionable diagnostics.
The generator validates all models before writing. Output is deterministic,
formatted and replaced through a unique temporary file. Hand-written files and
symbolic links are not overwritten. `--check` compares without writing.

Tests cover golden output, conventions/annotations/aliases/constructors, negative
diagnostics, CLI ownership/staleness, and compiled generated consumers performing
migrations, linked CRUD, revisions, queries, relationships and reopen/read.
Analyzer 6.4.1 and dart_style 2.3.6 are intentionally pinned for the tested SDK.
They are generator dependencies; the ORM runtime does not depend on them.
