# sqlite_plus

Pure Dart SQLite-compatible database engine and convention-based ORM (early development).

This repository is a starter scaffold, not yet a SQLite implementation. The long-term goal is an independent SQLite-compatible engine without FFI/native runtime SQLite and a generated Entity Framework-style Dart ORM.

Read `MASTER_SPEC.md`, `AGENTS.md`, `IMPLEMENTATION_PLAN.md` and `COMPATIBILITY_MATRIX.md` before developing.

## Packages
- `packages/sqlite_plus`: engine foundation
- `packages/sqlite_plus_orm`: planned ORM
- `packages/sqlite_plus_generator`: planned metadata generator

## Verification
Install the Dart SDK, then run `cd packages/sqlite_plus && dart pub get && dart analyze && dart test`.

Use GitHub Actions for CI. No SQLite compatibility claims are made by this starter.
