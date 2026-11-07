# Changelog

## Unreleased — built-in pagination

- Integrated keyset `.page()` API with forward/backward portable cursors.
- Multi-column ASC/DESC, NULL placement, key tie-breakers and query-scope validation.
- Engine/read-only API and ORM filters, codecs, serialization and tracking.
- No stored format migration, automatic indexes or change to skip/take behavior.

## Unreleased

- Native typed watch/watchFirst/watchCount/watchAny with independent snapshots.
- Optional Changes-backed connection observes captured external/Sync commits.
- Lazy subscriptions, dependency filtering, shared reads and lifecycle cleanup.
- Adds local unpublished Reactive/Changes dependencies; publication remains pending.

## 0.1.9

Depends on `sqlite_plus` ^0.1.9. The README opens on `books.db`. The library behavior is the 0.1.8 release.

## 0.1.8

Depends on `sqlite_plus` ^0.1.8. The library behavior is the 0.1.7 release.

## 0.1.7

Depends on `sqlite_plus` ^0.1.7.

- A generated integer key named `rowid`, `oid`, or `_rowid_` is the SQLite row id when the table has no `PRIMARY KEY` and `table_xinfo` does not list that name. `plan()` does not rebuild the table for that key.
- A declared primary key, a `WITHOUT ROWID` table, and any other missing column still require a reviewed migration.
- The README links the other packages on pub.dev, including a short example of each.
- `DbSet.openMemory` and `DbSet.openDbFile` remain. A second `openDbFile` of the same path while the first owner is open throws `StateError`.

## 0.1.6

Depends on `sqlite_plus` ^0.1.6. Published number for the 0.1.4 library.

## 0.1.4

Depends on `sqlite_plus` 0.1.5.

- `@DbDocument()` stores one object as JSON text. `Codecs.document` calls `fromJson` and `toJson`. `row.card.path(r'$.title')` binds `json_extract`. A returned row is decoded. The other rows stay text.
- The model schema records `"document": true` for that column. The SQL type stays `TEXT`. A `String` column still uses `@DbJson`.
- `DbModules`, `DbTokenizers`, and `DbVectorMetrics` are documented `String` constants. `DbVectorLimits` documents 1 and 4096. The annotation fields stay strings, so a missing name can still be written by hand.
- `@DbEntity(module:, tokenizer:)` creates `fts5`, `rtree`, or `vec0`. An unknown module is rejected. A tokenizer belongs on `fts5`.
- `@DbVector(dimensions)` stores `List<double>` as little-endian float32. The default metric is `l2`.
- `search` queries an FTS5 table. `nearest` writes `column MATCH ? AND k = ?` and orders by `distance`.
- `sqlite_plus_arabic` and `sqlite_plus_vec` are registered by the application. This package does not import them.

## 0.1.3

Depends on `sqlite_plus` 0.1.3. pub.dev already serves `0.1.2`.

- `@DbScalar()` on an instance method or getter reads mapped fields. `selectWhere((row) => row.twice() > 20)` runs that body for each row. The context registers `table_method` on the connection.
- A column, a JSON path, or a call accepts the engine scalars: `abs`, `upper`, `lower`, `length`, `trim`, `substr`, `replace`, `round`, `coalesce`, `ifNull`, `concat`, `sign`, `floor`, `ceil`, `sqrt`, `date`, `time`, `dateTime`, `unixEpoch`, and `julianDay`.

## 0.1.2

Depends on `sqlite_plus` 0.1.2. The page uses the Linux release-build sample and the new logo.

## 0.1.1

The package page leads with a save, a revision, and a JSON path. Depends on `sqlite_plus` 0.1.1.

## 0.1.0

Release number. Depends on `sqlite_plus` 0.1.0.

## 0.0.3

Release number. Depends on `sqlite_plus` 0.0.3.

## 0.0.2

Published release. Depends on `sqlite_plus` 0.0.2.

## 0.0.1-dev.1

First pre-release.

- Typed queries, change tracking, relationships, and reviewed migrations.
- The reading-log example ships with the package.
