# Inspector development milestone

- [x] Independent opt-in wrappers; no engine/ORM execution hooks or stored schema.
- [x] Bounded records/groups/scopes, slow queries, failures, counts and JSON reports.
- [x] Default literal/bind redaction and optional bounded parameter previews.
- [x] Nested/concurrent named operation scopes and repeated-read heuristics.
- [x] Mutable/read-only, file owner/client and ORM adapters preserving ownership,
  Changes transaction driver, migrations, scalars and Reactive query execution.
- [x] Explicit SELECT plan inspection, never automatic query re-execution.
- [x] Positive/negative/boundary/lifecycle tests, VM/Node examples and native plans.
- [x] AOT direct/disabled/enabled evidence, docs and CI.

Experimental/unpublished. No UI/server, telemetry, automatic indexes, universal
N+1 diagnosis, engine CPU attribution, internal trigger/Sync/Search interception
or production/platform guarantee. Wrappers observe only calls through them.


Verified: 25 inspector tests + 209 existing ORM tests; native pinned SQLite
plan/result comparison, VM/Node assertions, clean analysis/format, five-process
AOT runs per mode/size at 1000/10000 rows. Existing runtime hashes unchanged.
No remote CI/real device/browser/UI or release gate advanced.
