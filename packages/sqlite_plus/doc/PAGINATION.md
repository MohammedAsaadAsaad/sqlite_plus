# Cursor pagination in sqlite_plus and ORM

Unreleased workspace feature, integrated into the existing packages. No new
package, schema migration, persistent cursor table, automatic index or background
work. Existing `query`, `skip`, `take`, `count` and reactive APIs keep their behavior.

## ORM

```dart
final query = context.set(productType).query
    .where(price.lt(100))
    .orderBy([price.asc()]);

final first = await query.page(size: 30);
final second = await query.page(size: 30, after: first.nextCursor);
final back = await query.page(size: 30, before: second.previousCursor);

// Persist or send a continuation token:
final token = first.nextCursor?.encode();
final restored = token == null ? null : PageCursor.parse(token);
```

Check a cursor for null before navigating: passing `after: null` or `before: null`
starts the first page. `SqlPage<T>` contains `items`, `hasNextPage`,
`hasPreviousPage`, `nextCursor` and `previousCursor`. Reverse navigation returns
rows in the original presentation order, not reversed order.

Mapped primary keys (including composite keys) are appended to the order if
missing, in ascending order. If there is no order, use primary-key order.
This separates rows with the same price. Explicit key ordering is preserved.
The default page size is 30, allowed sizes 1–10000. Changing size is supported;
changing it on reverse navigation naturally changes page boundaries.

ORM filters, ownership serialization, codecs and normal tracking apply.
`asNoTracking().page(...)` creates independent entities. By default the identity
map may return an existing dirty entity, just as `toList` does; the cursor is
always built from database row values before materialization, never dirty fields.
Generated mappings need no new generated API.

Cursor paging rejects existing `skip/take` windows, FTS-rank/vector-distance
ordering, non-column ordering (JSON paths/scalar calls), and registered
non-deterministic scalars. Ordinary mapped-column ordering and filters are
supported. `.page()` returns a Future; it does not create a reactive subscription.
[Complete ORM assertion example](../../sqlite_plus_orm/example/pagination.dart).

## Direct engine API

`MutableSqliteDatabase`, read-only `SqliteDatabase`, and the file-owner
`DatabaseClient` expose `.page()` (the client extension is exported from
`sqlite_plus_io.dart`). Pages execute through the same client/transaction:

```dart
final page = await db.page(
  table: 'products',
  keyColumns: ['id'],
  orderBy: [PageOrder('price', descending: true, nullsFirst: false)],
  where: 'category_id = ?',
  parameters: [categoryId],
  size: 30,
  after: cursor,
);
```

Raw pages contain immutable row maps with SQL values (`BigInt` for INTEGER).
BLOB values are copied; mutating a returned BLOB cannot alter its cursor.
An optional `columns` projection must include every ordering/key column. Names
are quoted as identifiers; they are not SQL expressions. `table` is one table or
view name (not a schema-qualified SQL fragment). `where` is an application-owned
SQL expression; bind user values through `parameters`. This convenience API does
not parse arbitrary SELECT/JOIN/GROUP BY statements. A view can expose a supported
query shape when its output has stable, unique keys.

`SqlPagination(queryRunner)` exposes the same implementation for custom query
connections and is what ORM uses. It executes one SELECT with `size + 1` lookahead,
with no hidden COUNT or opposite-direction existence query.
[Complete engine assertion example](../example/pagination.dart).

## NULL, collation and unique keys

Each ordering column supports ASC/DESC and explicit `nullsFirst`. Defaults match
SQLite: NULL first ascending and last descending. Boundary predicates handle
NULL separately and compare lexicographically across the ordered columns.
Reversing direction reverses both sort direction and NULL placement.

`PageOrder.collation` optionally selects a collation; otherwise the column's
SQLite collation applies. Equality prefixes and range predicates use the same
collation as sorting. An explicit override on a key adds a final BINARY key
ordering term so NOCASE cannot collapse distinct binary text keys.

Direct callers guarantee that `keyColumns` are globally unique and non-null
under their effective default column comparison semantics. Prefer actual
primary/unique keys whose declared column collations match their uniqueness
constraint. The helper checks returned/lookahead rows for NULL/duplicate key
values, but does not scan the table to prove global uniqueness or inspect every
index's collation. Incorrect keys can skip rows. Custom collations must remain
deterministic and unchanged while continuing a cursor. ORM keys must likewise
match the actual source schema.

## Cursor validation and consistency

Tokens are versioned Base64url JSON containing a SHA-256 query-definition digest
and typed boundary values. Integers use decimal strings, preserving signed
64-bit values on JavaScript; BLOBs use Base64. NaN/infinity and out-of-range
integers are rejected when encoding/parsing tokens or validating filter parameters. Use `BigInt` for input integers outside ±9007199254740991.
At most 16 effective ordering columns and 64 KiB encoded tokens are supported.

The digest covers table, projection, filter SQL/binds, effective order, key
columns and optional `cursorScope`. A cursor from a different query is rejected.
Page size/direction are intentionally not bound. Supply a stable scope such as
`tenant-42/schema-v3` when database, tenant, schema or collation changes must
invalidate previously saved tokens. The digest is not a signature: tokens are
readable and forgeable, may expose ordering values, and never grant permission.
Always apply the caller's authorization filter again.

Keyset navigation resumes by boundary values; it does not need the anchor row
still to exist. Inserting/removing earlier rows does not shift an OFFSET and
therefore does not shift the continuation boundary. Changing an ordering value
can move a row across the boundary and cause it to appear again or be missed.
Separate page calls are not a database snapshot or an exactly-once export.
Use a caller-owned read transaction/snapshot when the full traversal must be
consistent; the helper never begins or commits one itself.

The flag in the fetched direction is established by the extra row. The opposite
flag is a navigation hint based on the supplied boundary and a nonempty result;
it is not a second existence check. Concurrent removals can make that direction
empty. Empty pages return no cursors; retain your prior cursor/history or restart.
There is no total count, page-number jump or guarantee of the same partition
after writes or a page-size change.

## Performance and storage

The helper builds a keyset WHERE predicate and bound LIMIT instead of OFFSET.
Appropriate indexes may avoid revisiting earlier rows. An index matching the
filter's equality prefix followed by ordering/key columns is a useful starting
point. Review the actual query plan before creating one: mixed directions,
collations, NULL placement and OR predicates can require scans/sorts in the
current planner. No universal O(log N) or speedup claim.

Each page retains at most `size` rows plus one temporary lookahead row in the
helper, but the engine may materialize/sort more source rows internally. Wide
BLOBs and strings remain proportional to their byte sizes. Query validation,
SHA-256, key checking and row-map creation have CPU/allocation costs. Ordinary
operations never call this helper, and no interception hook is installed.

See [AOT evidence](../../../benchmark_results/pagination/README.md). Tests cover
VM, Node-compiled examples, file-owner cursor reopen, a simulated browser store,
Changes adapter reads and pinned SQLite 3.53.1 ordering. No real browser/device
performance or persistence claim; no packages published by this change.
