import 'storage_backend.dart';

/// A capability contract, not a claim about an arbitrary filesystem adapter.
///
/// Implementations must persist every successful write/truncate before sync()
/// completes; completed syncs survive a crash and impose write ordering. The
/// backend's directory entry must already be durable, and storage must support
/// overwriting/truncating without replacing that entry. Callers must exclude
/// other writers. Ordinary MemoryStorageBackend and the read-only file adapter
/// intentionally do not implement this contract.
abstract interface class DurableStorageBackend implements StorageBackend {}
