# SQLite compatibility matrix

Reference: **SQLite 3.53.1**, source ID
`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`.
The exact oracle compile options and fixture SHA-256 hashes are recorded in
`packages/sqlite_plus/test/fixtures/manifest.json`. This pins the development-only
Python SQLite oracle, not a production dependency. No SQL compatibility is claimed.

| Feature | Status | Verification |
|---|---|---|
| Pure Dart in-memory byte storage | Implemented | 5 tests pass on Dart 3.13.7/Linux x64 |
| SQLite 100-byte database header | Implemented | Big-endian fields, signed cache size, page-size sentinel, format checks, reserved bytes, stale size handling |
| B-tree page framing | Implemented, limited scope | All four types, page-one offset, pointer bounds/duplicates, freeblock chain, fragments, reserved tail; 29 SQLite-created pages compared with dbstat |
| Binary fixtures / development oracle | Implemented | 512/4096/65536-byte pages; UTF-8/UTF-16le/UTF-16be; integrity_check, checksums, deterministic regeneration |
| SQL parser and execution | Not started | — |
| Transactions and WAL | Not started | Header versions recognized only; no WAL reading or recovery |
| SQLite file interoperability | Header/page framing only | No record decoding, cross-open writes, pager or complete corruption detection |
| ORM and code generator | Placeholders | Analyzer passes; no behavior or tests yet |
| Linux x64 | Development checks verified | 20 engine tests, formatting and analysis pass |
| Windows/macOS/Android/iOS/Web | Not verified | Pure Dart runtime sources; platform execution not tested |

Page validation is structural, not a complete database integrity check. Cell sizes,
payloads, overflow chains, child-page references, cross-page consistency and
freelist trunk pages require later milestones. Crash recovery is not applicable to
these read-only decoders. SQLite fixture creation uses native SQLite only as a
development oracle; the Dart runtime imports only Dart libraries.
