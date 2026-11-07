## Unreleased

- Add scoped consumer reads/acknowledgements so database-local output commits
  atomically with consumption; pending-event/checkpoint and source inspection
  support application origin markers without changing the stored log format.
- Add `resumeExisting` for consumer creation with a fallback starting position.

- Benefit from the workspace engine's narrower temporary trigger-read snapshots;
  capture API, stored log format, transaction ordering and retention stay the same.
- Add paired AOT comparisons for enabled and disabled workloads at 1k/10k rows.
  Results require the current unreleased engine revision; this is not a claim
  about the published 0.1.9 engine or physical-device performance.

## 0.0.1-dev.1

- First development milestone: opt-in transaction-scoped key/column changes,
  typed composite keys, whole-transaction delivery, named durable consumers,
  explicit acknowledgment/reset, retention and generation rotation.
- No changes to existing engine/search runtime. Disabled before/after AOT gate
  includes matching database images. Enabled write performance remains a major
  limitation; see README and benchmark results before enabling.
- No transparent raw-transaction interception, automatic quotas, atomic consumer
  output/ack helper or production-ready write performance claim.


### Reactive integration (unreleased workspace)

Optional post-commit/reset hints, stateless `readSince` and serialized `exclusive`
scopes. No durable watcher consumer or stored format migration. Existing consumer
read/ack and source transaction APIs retained.
