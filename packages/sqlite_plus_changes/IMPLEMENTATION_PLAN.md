# First development milestone

- [x] Capture baseline AOT executable before introducing package.
- [x] Independent opt-in package using only the public pure-Dart engine API.
- [x] Transaction-scoped key/column capture, typed composite keys, savepoints.
- [x] Whole-transaction consumers with durable delivery/ack/reset positions.
- [x] Safe/forced pruning, expiry and explicit generation rotation.
- [x] Schema checks, missing-event detection, native differential/cross-open tests.
- [x] Crash injection: capture, ack, prune and track; delete/persist journals.
- [x] VM and Node signed64/image assertions; existing search coexistence.
- [x] Paired disabled AOT measurements, enabled cost/size measurements.
- [x] Reduce enabled producer cost via dependency-limited trigger-read snapshots.
- [x] Repeat paired enabled/disabled AOT and native/recovery regression checks.
- [x] Adopt the verified optimization as the development baseline; document setup,
  API, consumer lifecycle, measured performance and remaining release gates.
- [ ] High-write-volume adoption: persisted/device and larger retained-log tests.
- [x] Atomic scoped read/output/ack and pending-event inspection for Sync.
- [ ] Filtered subscriptions and notifications.
- [ ] Transparent engine/ORM transaction interception and shared search adapter.
- [ ] Automatic byte/age limits, data-value/history capture, external writers.
- [ ] Real browser storage, device and WAL-specific package recovery validation.

The current catalog does not enable tracking. No existing search log migration
or publication is performed. This package is not a production release.
