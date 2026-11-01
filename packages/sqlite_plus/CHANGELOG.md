# Changelog

## Unreleased

The version number stays `0.1.2`. Compared with pinned SQLite 3.53.1 on Dart 3.13.7, Linux x64. 10596 tests passed.

- Incremental auto-vacuum keeps the freelist page after an overflow delete. `incremental_vacuum` moves a live end page, then truncates.
- Contentless FTS4 stores no content table and returns the pinned `MATCH` row. FTS3 `content=''` is a column named `content`.
- File `journal_mode` `wal`, `persist`, and `truncate` follow the pinned header and journal bytes. This is not a multi-frame WAL log.
- Cross-schema `VALUES` errors use the pinned wording.
- `EXPLAIN` matches the pinned opcode rows for a constant subquery, an integer-primary-key scan, `WITHOUT ROWID`, a virtual generated column, a typed `INSERT`, and a multi-row `VALUES` insert. An integer-primary-key insert and a join of two subqueries stay rejected. This is not a VDBE.

## 0.1.2

Performance work and a Linux desktop experiment. A release build compared 1,000 rows with sqflite. Every checksum matched. The charts are that sample. The logo is the feather, the database, and the plus.

## 0.1.1

Package page: short SQL, JSON, search, and file samples, plus the measured 1,000-row comparison.

## 0.1.0

`openInMemory` is `MutableSqliteDatabase.create`. `openDatabase` is `DatabaseOwner.open`. The previous names remain.

## 0.0.3

Published release.

## 0.0.2

Published release. Same engine surface as the first pre-release.

## 0.0.1-dev.1

First pre-release.

- Pure Dart SQL, JSON, FTS5, R-tree, and geopoly.
- In-memory databases, `exportImage`, and a `dart:io` file adapter.
- The package README shows the 1000-row comparison with Android SQLite.
