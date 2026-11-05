# Changelog

## 0.1.2

`rankVec0` scores a `vec0` shadow table one page at a time. Pass the eligible row ids and every one of those rows gets a distance; an empty list reads nothing. `embedding MATCH ? AND k = ?` is unchanged and still applies `k` before a later SQL filter. A `MATCH` scan keeps the embedding bytes of the returned neighbors rather than a second copy of every stored blob.

## 0.1.1

Depends on `sqlite_plus` ^0.1.7. `vec0` is unchanged. The README links the other packages on pub.dev and shows a short example of each.

## 0.1.0

Brute-force `vec0` virtual table for one little-endian float32 column.

- `SqlitePlusVec.register` accepts a `SqliteDatabase`, a `MutableSqliteDatabase`, or the connection's `SqlFunctionRegistry`.
- `CREATE VIRTUAL TABLE ... USING vec0(embedding float[N] distance_metric=l2|cosine)` scans every row for `embedding MATCH ? AND k = ?`.
- `vecDistance`, `encodeVec`, and `decodeVec` are the same float32 math. Dimensions are 1 to 4096. `k` is 1 to 100000.
- An ORM table uses `DbModules.vec0` and `@DbVector`. `nearest` returns the `k` closest rows.
- The scan is not an approximate index. The file is not a sqlite-vec database.
