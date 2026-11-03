# Changelog

## 0.1.4

Depends on `sqlite_plus` 0.1.3. `sqlite_plus` stays `0.1.3`.

- `@DbDocument()` stores one object as JSON text. `Codecs.document` calls `fromJson` and `toJson`. `row.card.path(r'$.title')` binds `json_extract`. A returned row is decoded. The other rows stay text.
- The model schema records `"document": true` for that column. The SQL type stays `TEXT`. A `String` column still uses `@DbJson`.

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
