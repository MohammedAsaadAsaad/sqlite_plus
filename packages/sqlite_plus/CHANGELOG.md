# Changelog

## 0.1.7

The README names every package on pub.dev and shows a short example of each. The engine behavior is the 0.1.6 library.

## 0.1.6

Published version of the 0.1.5 library. `sqlite_plus_orm` 0.1.6 and `sqlite_plus_generator` 0.1.6 depend on this version.

## 0.1.5

Custom FTS tokenizers and row-storing virtual tables on Dart 3.13.7, Linux x64. 10609 tests passed.

- `tokenizers.register` adds an FTS tokenizer. `unicode61`, `porter`, `trigram`, `ascii`, and `simple` cannot be replaced.
- `VirtualTableModule.storesRows` creates a shadow table. `INSERT`, `UPDATE`, and `DELETE` write that table. `DROP` removes the shadows named by `ownedShadows`.
- A `MATCH` handler on the statement's virtual-match board can answer a virtual table before FTS does.
- `sqlite_plus_arabic` and `sqlite_plus_vec` use these hooks. The engine does not contain the Arabic stemmer or the vector distance math.

## 0.1.4

SQLCipher 4 file codec on Dart 3.13.7, Linux x64. 10607 tests passed. An unencrypted database does not run it.

- `SqlCipherDatabase.create` and `open` keep a plaintext database whose header reserve is 80 bytes. `encryptedImage` is AES-256-CBC with HMAC-SHA512. The key is PBKDF2-HMAC-SHA512, 256000 iterations by default. The HMAC key uses the salt with each byte XOR `0x3a` for 2 iterations.
- Page 1 stores a 16-byte salt. A wrong passphrase, a changed byte, or a page moved to another number fails authentication.
- A SQLCipher 4.5.6 community file with the default schedule opens here. A file written here opens in that CLI when both sides use the same iteration count. `saveSqlCipher` replaces the whole file. It is not the rollback journal.
- WAL files, SQLCipher 1–3, rekey, a plaintext header, and auto-vacuum combined with the reserve are unsupported.
- A reserve of 0 keeps the previous page geometry. A nonzero reserve rebuilds when auto-vacuum is off.

## 0.1.3

Compared with pinned SQLite 3.53.1 on Dart 3.13.7, Linux x64. 10596 tests passed. pub.dev already serves `0.1.2`.

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
