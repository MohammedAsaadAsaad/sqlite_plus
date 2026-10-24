# Codex engineering instructions

Read `MASTER_SPEC.md`, `IMPLEMENTATION_PLAN.md`, `COMPATIBILITY_MATRIX.md`, and `DEVELOPMENT_LOG.md` before changing code.

- Pure Dart production runtime; no FFI, native SQLite, WASM SQLite, or platform-channel database execution.
- Implement one approved milestone at a time; do not claim unverified compatibility.
- Add positive, negative, boundary, and regression tests for each feature.
- Run `dart format .`, `dart analyze`, and `dart test` for affected packages.
- For storage changes, include corruption and crash-recovery tests as applicable.
- For SQL changes, compare against pinned official SQLite using development-only tooling.
- For performance changes, collect reproducible AOT benchmarks, not invented numbers.
- Never silently migrate destructive schema changes.
- Update compatibility matrix and development log after each verified milestone.
- Document missing toolchains and unrun tests explicitly.
