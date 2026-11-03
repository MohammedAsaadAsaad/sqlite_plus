# Changelog

## 0.1.0

Brute-force `vec0` virtual table for one little-endian float32 column.

- `SqlitePlusVec.register` accepts a `SqliteDatabase`, a `MutableSqliteDatabase`, or the connection's `SqlFunctionRegistry`.
- `CREATE VIRTUAL TABLE ... USING vec0(embedding float[N] distance_metric=l2|cosine)` scans every row for `embedding MATCH ? AND k = ?`.
- `vecDistance`, `encodeVec`, and `decodeVec` are the same float32 math. Dimensions are 1 to 4096. `k` is 1 to 100000.
- An ORM table uses `DbModules.vec0` and `@DbVector`. `nearest` returns the `k` closest rows.
- The scan is not an approximate index. The file is not a sqlite-vec database.
