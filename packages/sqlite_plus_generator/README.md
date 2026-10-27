# sqlite_plus_generator

A development-only resolved Dart generator for sqlite_plus_orm. It inspects
analyzer elements and constant annotations without importing or executing model
code. Generated runtime mappings use only the public ORM API.

```sh
dart run sqlite_plus_generator --input lib/models.dart
dart run sqlite_plus_generator --input lib/models.dart --check
```

The source imports sqlite_plus_orm and declares `part 'models.orm.g.dart';`.
Use repeated `--class Name` options to select classes, and `--output` for a
matching alternative part path. The repository example is reproducible with:

```sh
dart run bin/sqlite_plus_generator.dart --input example/models.dart --check
```

Conventions select concrete public classes with `id`/`<ClassName>Id`. SQL names
default to exact Dart names. Optional DbEntity, DbColumn, DbIgnore, DbKey,
DbVersion and DbReference annotations override conventions, using resolved type
identity and supporting import prefixes. DbReference.column names a target Dart
property; absent that, the target needs one primary key.

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
