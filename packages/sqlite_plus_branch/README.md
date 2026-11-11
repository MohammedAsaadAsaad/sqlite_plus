# sqlite_plus_branch

Experimental, unpublished full-copy branches for the pure-Dart sqlite_plus engine.
Create an isolated working database, compare its final rows with an immutable
base, then perform a three-way field merge into the current source. No engine
runtime changes, automatic capture triggers or tracking hooks are installed.

This first version prioritizes correctness and explicit limits. It copies complete
SQLite images and scans supported tables; it does not share pages or implement
Git's storage format. The base and working images both live in memory.

## Release status

This is a workspace development package (`publish_to: none`). An independent
installation against published sqlite_plus_orm 0.1.11 currently fails analysis
of example/orm.dart: that published version lacks the new upsert/update methods.
Declare and independently verify a compatible ORM release before releasing this
package, or adapt the example to published APIs. Upstream main subsequently
bumped ORM to 0.1.12; the independent check described here used 0.1.11.
A publish dry-run also recommends repository/homepage metadata. Neither local
workspace checks nor the dry-run establish production or public-release readiness.

## A complete beginning-to-merge example

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';

Future<void> main() async {
  final db = await openInMemory();
  await db.execute('CREATE TABLE products('
      'sku TEXT PRIMARY KEY NOT NULL,price INTEGER NOT NULL,stock INTEGER NOT NULL)');
  await db.execute("INSERT INTO products VALUES('BISCUIT-001',500,100)");

  // The application supplies a stable logical source identity. Persist it with
  // your configuration and reuse it only for this database's branch family.
  final branches = SqlitePlusBranches(database: db, sourceId: 'my-catalog');
  final draft = await branches.create(name: 'new-prices');
  try {
    await draft.database.execute('UPDATE products SET price=550');
    await db.execute('UPDATE products SET stock=97');

    final diff = await draft.diff();
    print(diff.single.changedColumns); // [price]

    final preview = await draft.previewMerge();
    if (preview.conflicts.isEmpty) {
      final result = await draft.merge(preview: preview);
      print(result.appliedRows); // 1
    }
    // Main now has price=550 and stock=97. Branch stock remains 100.
    print((await db.query('SELECT price,stock FROM products')).rows);
  } finally {
    await draft.close();
    await db.close();
  }
}
```

See the [executable SQL example](example/main.dart), including archive restore and
safe retry, and the [complete ORM example](example/orm.dart). Prices in those
examples are integer minor currency units (500 = 5.00).

## Three-way conflicts

Only branch changes relative to its base are candidates. Main-only changes are
preserved. Equal final values are not conflicts; changes reverted to their base
value disappear from the diff. Different columns can merge independently.
Changing a primary key appears as a deletion and insertion. INTEGER and REAL
values with exactly equal numeric value compare equal (including 1 and 1.0) on
VM and JS; changes only to their storage class are not a logical diff. Text and
BLOB values remain type-sensitive.

If base price=500, main=520 and branch=550, the preview contains one field conflict:

```dart
final preview = await draft.previewMerge();
final resolutions = <String, BranchResolution>{};
for (final conflict in preview.conflicts) {
  print('${conflict.table} ${conflict.key} ${conflict.column}');
  print('${conflict.baseValue} / ${conflict.mainValue} / ${conflict.branchValue}');
  // Application/user policy chooses explicitly; this example keeps branch.
  resolutions[conflict.id] = const BranchResolution.useBranch();
}
await draft.merge(preview: preview, resolutions: resolutions);
```

Alternatives are `const BranchResolution.useMain()` or
`BranchResolution.value(530)` for a field. Custom values must be finite SQL storage
values compatible with the destination; coercion that changes the reviewed
storage value is rejected. BLOB inputs and returned diff/conflict maps are copied.

Row-level insert/insert, delete/update and update/delete conflicts accept
useMain/useBranch only; `column` is null, and baseRow/mainRow/branchRow expose the
full rows. A deletion is null. `kind` identifies the conflict. Numbers are values,
not inferred increments: the package never assumes that 100→90 means subtract 10.

Unresolved conflicts throw `BranchConflictException`, containing the preview.
Unknown resolution IDs fail. Supplying an old preview fails if either source or
working image changed, even due to an unrelated source write. A physical image
rewrite can conservatively invalidate the preview. Without a preview, merge
recomputes from current data; use the explicit preview for an approval UI.

## Transaction and constraint policy

Merge applies in one source transaction. Uniqueness, NOT NULL and CHECK failures
roll back everything, including the merge receipt. SQL conflict policies such as
IGNORE/REPLACE cannot silently publish a different result: the final logical state
of all supported tables is compared with the complete planned result.

Foreign-key actions are temporarily disabled on the exclusively loaned source;
all final foreign keys are checked before commit, and its previous setting is
restored. This prevents CASCADE/SET NULL from modifying unreviewed rows. A new
main-side child can therefore block a branch parent deletion. Branch-side cascades
run only if the application explicitly enables foreign_keys on its working engine.

Unique constraints are immediate. Some otherwise valid multi-row unique-value
swaps can fail due to intermediate values; there is no automatic key remapping,
staging of unique values or automatic retry. Generated integer key collisions
remain explicit insert conflicts. Prefer application-assigned stable IDs.

## Checkpoints, reopen and interruption

Writes affect an in-memory working connection until an explicit checkpoint:

```dart
final bytes = await draft.exportArchive();
// Persist bytes with your chosen storage adapter.
final reopened = await branches.restore(bytes);
// reopened has the original ID, base image and working image.
```

Archives contain versioned metadata and two base64 SQLite images, protected by a
SHA-256 corruption checksum. They are plaintext, not encrypted or authenticated;
sourceId and checksum are not a security boundary. Restore validates schema,
values and budgets. It copies input bytes and rejects the wrong sourceId. Main
is untouched by create/diff/preview/export/restore. Names are labels, not unique
identities; generated IDs identify branches. There is no directory-wide registry.

On VM, use the optional IO library for two-slot checkpoint storage:

```dart
import 'package:sqlite_plus_branch/sqlite_plus_branch_io.dart';

final store = await FileBranchStore.open('/existing/directory/prices');
try {
  await store.save(draft);
  final bytes = await store.readArchive();
  if (bytes != null) {
    final reopened = await branches.restore(bytes);
    // Use reopened, then await reopened.close().
  }
  // await store.delete(); // Durable-format tombstone, not secure erasure.
} finally {
  await store.close();
}
```

Files are `<path>.0`, `.1` and `.lock`. Alternate flushed, checksummed generations
allow fallback to the previous valid checkpoint after a torn newest write. Both
invalid slots fail closed. Unsaved edits are lost on interruption; an interrupted
save/delete may fall back to the earlier checkpoint. Old slot bytes are retained.
A checksum does not provide protection against deliberate modification.

Dart has no portable directory-fsync guarantee. The adapter does not promise
power-loss durability or multi-isolate ownership. Coordinate one owning isolate
per path; do not replace/delete lock files. The two slots retain up to four SQLite
images plus base64/JSON overhead. Browser callers can persist exportArchive bytes
using their own byte store; the IO entry point is not Web-compatible.

## Exactly one successful merge per branch

The first successful merge creates `_spb_merges` in main and records branch ID,
sourceId and working-image hash in the same transaction as the data. Reopening a
pre-merge checkpoint can therefore return `alreadyMerged: true` after a commit,
without reapplying it—even if main changed later. Receipt schema is validated and
excluded from application diffs. Never edit/delete these records to reclaim space;
retention/pruning is not implemented. Receipts accumulate and count toward image
size. Even a zero-change successful merge writes a receipt.

A branch is single-use for merging. After success, create a new branch for further
work. Its raw working engine is not read-only, but changed contents cannot reuse
the committed identity. Commit uncertainty poisons further manager operations on
that source engine; close/recover it and restore a saved archive. Recovery follows
the source ImagePager's atomic commit contract. In-memory sources remain volatile;
saving a branch does not make its main database persistent.

## ORM and generated columns

```dart
import 'package:sqlite_plus_branch/sqlite_plus_branch_orm.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

// ProductMapping / ProductColumns come from sqlite_plus_generator output for
// your annotated Product model. They are not supplied by this package.
final context = DbContext(draft.ormConnection,
    DbModel([ProductMapping.instance]));
try {
  await context.set(ProductMapping.instance).query
      .where(ProductColumns.sku.eq('BISCUIT-001'))
      .update({ProductColumns.price: 550});
} finally {
  await context.close(); // Leaves draft open.
}
await draft.merge();
```

The runnable ORM example defines every Column/EntityType manually and explicitly
names their generated equivalents. No hidden Product class or generated file is
required to run it. See ORM's [mapping-origin walkthrough](../sqlite_plus_orm/doc/DIRECT_WRITES.md#where-do-the-column-variables-come-from)
for a model, generation command and manual/generated name comparison.

**Finish/save and close ORM contexts before branch operations.** No implicit
saveChanges occurs. Create a fresh main context after merging. Managed version
fields are ordinary three-way merged values here, not additionally incremented by
the merge. Existing main tracking and Reactive snapshots are not refreshed.

## Ownership, supported schema and limits

- One same-isolate MutableSqliteDatabase source, exclusively loaned during each
  manager call. No raw SQL, ORM or other package operation may interleave it.
  Manager calls on the same source queue; branch calls reject overlap. The package
  cannot enforce exclusivity against external raw handles.
- Main schema only. TEMP, ATTACH, custom registry/connection settings and caches
  are not cloned; source and branch operate through separate connections.
  Source ownership/closing belongs to the application, branch.close owns working.
- All ordinary tables require explicit non-null, affinity-correct primary-key
  values: INTEGER, TEXT or BLOB, including composite keys, with BINARY key
  collation. WITHOUT ROWID, ordinary indexes, views and final FK checks are covered.
- Triggers, virtual tables (including Search/FTS, Geo/R-tree, Vec), generated
  columns and schema changes are rejected. Changes capture triggers and Sync or
  Reactive transaction integration are not supported in this first version.
  The package never bypasses another package's guards. Inspector may observe
  separately wrapped branch SQL, but no engine-wide interception is installed.
- The exact application schema SQL and user_version/application_id/encoding must
  match the base on both sides. sqlite_sequence/statistics and hidden rowids are
  not logical merge targets. Reindexing or running a migration belongs outside
  this milestone. `_spb_` names are reserved.
- Defaults: 32 MiB per SQLite image, 10,000 total application rows per snapshot,
  64 tables, 128 columns/table. Configure BranchLimits explicitly for larger
  inputs. Archive cap is 3× image budget + 16 KiB; default IO archive cap matches
  default limits and must be raised separately if needed. These are input limits,
  not a strict heap cap: export, comparison and verification keep multiple copies.

## Performance and validation

Complete images are copied; comparisons scan rows and encode identities. Small
changes do not make diff/merge proportional only to changed rows. Full expected
state verification is deliberate. No source tables or write hooks are added until
a merge, and no existing engine/ORM runtime source was modified.

[AOT measurements and limits](../../benchmark_results/branch/README.md) report
create/diff/preview/archive/merge separately, plus image/archive sizes. They do not
prove zero timing overhead, shared-page efficiency or large database suitability.

Tests cover field/row conflicts, stale approvals, constraints and FK rollback,
64-bit/BLOB identities, archive validation, two-slot recovery, process exit,
uncertain commit before/after pager persistence, ORM and pinned SQLite cross-open
integrity for three encodings. VM and compiled JS/Node assertions run locally;
real browser/device and cross-platform CI are separate gates.

## Operation preview

`preview` is a convenience inside Branch; it creates an ordinary isolated branch
and runs the callback once. Its argument is a MutableSqliteDatabase, so write
`draft.execute(...)`, not an undeclared domain API:

```dart
final preview = await branches.preview((draft) async {
  return draft.execute('UPDATE products SET price=550 WHERE sku=?', ['A']);
}, name: 'price-change');
try {
  print(preview.value.affectedRows); // Callback result, not a cloned business object.
  print(preview.changes); // Exact reviewed row differences.
  print(preview.conflicts);
  await preview.merge(); // Explicit acceptance; callback is never rerun.
} finally {
  await preview.close(); // Discard/release working memory, idempotent sequentially.
}
```

The preview retains its original review token. Any later source edit or escaped
working-engine edit invalidates acceptance; conflict resolutions use the existing
BranchResolution IDs/policy. Callback/validation failures close the draft and
preserve the error. No exception is converted into an implicit approval or a list
of all possible DB constraint violations. External side effects in application
callbacks cannot be rolled back by this database feature.

Finish/save/close a draft ORM context inside the callback. Do not retain or close
the supplied engine. The callback result can be any Dart object and is not deeply
copied; only the reviewed database state governs merging. Existing branch schema,
image, source-ownership and single-merge limits apply. No separate Preview package.

The [complete prepared-import preview](example/import_preview.dart) defines its
model/columns first, validates/deduplicates input through ORM, applies on the
isolated draft, reviews actual differences and merges them without rerunning input.
