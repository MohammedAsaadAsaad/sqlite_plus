# Explicit diagnostics: candidate cost evidence

Status: **implemented, NOT accepted** (2026-11-11). Baseline is merged main
`056e9644fafb94de180dc6b761545be31e4a83f3`. PR #44 must remain a draft while
unused/default-path cost signals remain unresolved. Do not start item 6.

## Reproduce

From repository root, with Dart 3.13.7 and dependencies installed:

```sh
python3 tool/verify_optimizer_handoff.py --allow-unaccepted-diagnostics
python3 tool/optimizer_diagnostics_benchmark/build.py
# Stop compilers/tests before timing. These scripts run processes sequentially.
python3 tool/optimizer_diagnostics_benchmark/run.py
python3 tool/optimizer_diagnostics_benchmark/summarize.py
python3 tool/optimizer_diagnostics_benchmark/unused_controls.py
python3 tool/optimizer_diagnostics_benchmark/followup.py
python3 tool/optimizer_diagnostics_benchmark/blob_run.py
```

`build.py` reconstructs baseline library sources using the committed reverse
patch and verifies all source hashes before compiling. Raw results are retained;
subsequent candidate changes must archive these results before replacing them.
No CPU affinity was applied. These are in-memory AOT processes on this machine,
not device, file I/O, durability, allocation-count or release certification.

## What is measured

`runs.json` contains 11 cases × 3 variants × 5 processes: frozen baseline OFF,
current source linked but OFF, and explicit diagnostics ON. `summary.json`
checks identical result hashes, row counts, image sizes and page-read counts,
and bounded trace/privacy/counter invariants. Inputs vary between executions.
Timers surround the actual read/profile API; report serialization and result
hashing occur after timing. The mutable path includes its reader/image setup.

`unused_runs.json` tests the existing ordinary read/write, ORM and 100,000-update
programs which never invoke the new API. There are five paired processes per
control. `followup_runs.json` adds fifteen paired processes for four flagged
controls; `followup_summary.json` combines these with their original five.
Unrelated workloads and different affinity regimes are not pooled.

## Current result: investigation still required

After twenty samples per variant:

| Control | Baseline median ms | Candidate OFF median ms | Change |
| --- | ---: | ---: | ---: |
| Unused ordinary read | 36.693 | 38.824 | +5.81% |
| Linked point reader | 48.7395 | 48.4745 | -0.54% |
| Linked mutable point | 4.497 | 4.8765 | +8.44% |
| Linked 100k sort | 1326.0005 | 1327.626 | +0.12% |

The initial apparent point-reader and large-sort regressions largely disappeared
with more samples. The ordinary-read and mutable-point medians remain higher.
Overlapping ranges do not establish equivalence. Code-layout, timing noise and
iterator/callback specialization are hypotheses, not established causes. Do not
accept the item or advertise zero overhead from these results.

The first five-process matrix also shows visible enabled costs on short reads:
point-reader ON 54.194 ms versus linked OFF 46.874 ms, and Inspector point ON
14.880 ms versus OFF 11.283 ms. Some scan/sort ON medians are lower; diagnostics
is not an optimization and these results do not justify a speedup claim.

Unused ordinary binary sizes: baseline 10,171,680 bytes, candidate 10,171,800
(+120). Primary linked drivers: 10,238,400 versus 10,277,016 (+38,616 bytes).
These sizes are specific to the compiler/driver and are not package-size claims.

BLOB probe medians for twenty 1 MiB calls: reader baseline/OFF/ON
5.566 / 8.205 / 14.812 ms; mutable 5.022 / 5.247 / 20.281 ms. Five
processes per variant are exploratory; do not infer a stable OFF percentage
from this short, allocation-sensitive probe. Enabled redundant snapshots need
investigation while preserving pre-await binding isolation.

## Semantics and resource limits

The decision trace is capped at 0–256 entries; names are clipped to 128 Unicode
runes and SQL input is capped at 65,536 characters. These caps bound metadata,
not input/result/BLOB memory, ordinary materialization or database image copies.
The separate `blob_*` probe measures twenty 1 MiB bindings with baseline OFF,
linked OFF and ON, for read-only and mutable adapters. RSS is a process-level
observation, not an allocation counter or isolated trace-memory measurement.

Core source-preparation time includes planning; do not sum these overlapping
phases. Total core time excludes public argument snapshots and report creation;
the outer AOT timer includes them. Mutable routing and snapshot/reader creation
are outside core phase timers. `rowsLoaded` counts the materialized source,
`rowsVisited` counts evaluator consumption, and `rowsMatched` counts consumed
passing rows; early LIMIT can make these different. Reports intentionally omit
SQL, parameters and result values. Unknown key-visit, projection, sort-comparison
and allocation counters remain null. Full optimizer cost models, joins and
aggregates are outside this milestone.
