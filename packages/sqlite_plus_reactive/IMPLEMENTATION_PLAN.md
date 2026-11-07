# Reactive + ORM development milestone

1. [x] Preserve pre-feature ORM AOT binary and runtime hashes.
2. [x] Add optional Changes post-commit/reset signals and bounded stateless reads;
   no persistent watch consumers, metadata changes or polling.
3. [x] Reactive query registry: lazy initial read, shared SQL, dependency filters,
   coalescing, latest-state semantics, row diffs, manual refresh, lifecycle/errors,
   mutable-value isolation and bounded retained rows.
4. [x] ORM-native watch/watchFirst/watchCount/watchAny; typed metadata dependencies,
   read-only entity snapshots, queue/lifecycle ownership and clean close.
5. [x] Optional Changes-backed ORM transaction adapter; automatic mapped-source
   tracking; observe Sync/external Changes writes and preserve ordinary file/browser
   ORM saves without requiring Changes. Explicit unsupported capability errors.
6. [x] Race, rollback, pagination, sharing, dirty tracking, Sync/search, composite
   keys, storage, error/disposal tests, native SQL checks, VM/Node assertions.
7. [x] Existing ORM/generator/Changes/Sync regressions, AOT disabled/enabled evidence,
   README/example, compatibility and development log, CI.

Opt-in. No Flutter dependency, no publication/deployment or destructive schema
migration. No arbitrary cross-process/external SQL observation; unsupported raw
SQL dependency declarations require conservative invalidation/explicit refresh.
No promise of incremental JOIN/aggregate computation, exactly-once notifications,
or hard payload-byte bounds. Paused subscribers retain latest state only.


Verified: 315 combined ORM/Reactive/Changes/Sync tests, 78 generator tests;
VM/Node examples, pinned native differential SQL, analysis/format clean.
No real browser/device tests or remote CI run. Performance measurements are
complete, but strict zero-regression approval remains open: the shared-host
1000-row disabled update/count medians were +6.4%/+5.8%; see benchmark evidence.
No publication performed.
