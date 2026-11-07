# Sync development milestone 1

Accepted scope: one server namespace per database, explicit runOnce, stable typed
keys, server-assigned increasing revisions, durable state-based outbox, atomic
pull pages, default conflict rejection and explicit local/remote resolution.
Transport/authentication/server storage belong to an application adapter.

1. [x] Extend Changes without migrating its log: scoped read/ack, published-source
   descriptors and a nullable pending-batch checkpoint for origin markers.
2. [x] Define immutable typed protocol models and JSON codec; validate bounds,
   identities, revisions and transport replies before any state advances.
3. [x] Implement independent optional Sync metadata, idempotent registration and
   explicit bounded bootstrap of existing rows. Leave current apps unchanged.
4. [x] Atomically materialize/freeze outbox and ack Changes. Retry identical IDs
   and payloads, accept only complete server outcomes, preserve newer local edits.
5. [x] Apply pull pages/cursors in one transaction. Keep remote events available
   to other consumers while suppressing outbound echoes. Fail closed on incomplete
   dirty scans or expired/generation-mismatched checkpoints.
6. [x] Persist conflicts; explicit keepLocal/acceptRemote resolution. Never silently
   discard local writes. Include tombstones and key changes in the contract.
7. [x] Tests: two replicas, offline/retry/lost reply, concurrent local write during
   network waits, conflict resolution, malformed responses, rollback, recovery,
   SQLite differential/image checks and VM/compiled JS assertions.
8. [x] Reproducible AOT cost/size samples, disabled gate, README/example, workspace
   integration, compatibility/development log and required formatting/analysis.

Not production/release scope: automatic networking/background jobs, arbitrary raw
SQL/ORM interception, automatic backup-fork detection, peer-to-peer/CRDT merging,
server deployment/authentication, automatic retention/reset, real-device/browser
persistence guarantees. No native runtime, destructive migration or app activation.


Verified completion: 60 Sync tests, 38 Changes tests; 380 Sync and 80 Changes
injected operation fault points. Full engine 10,634 pass/one optional SQLCipher
skip; search 86 and catalog 17 pass. VM and compiled Node assertions pass.

Performance follow-up inside this milestone: multi-page/overflow schema root
reading plus image-scoped root caching removes repeated full reconstruction.
Writer-scoped Sync revision maps avoid repeated materialization while applying
acknowledgements. Catalog truncation remains restricted to the old safe shape.
Full raw AOT/size evidence and exact pre-Sync source reverse patches are retained.

This is a completed development milestone, not a production release. The transport
interface is implemented against a development reference server; real production
adapters, networking/persistence/device and scale gates above remain open.
