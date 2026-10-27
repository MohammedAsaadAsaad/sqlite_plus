import 'browser_byte_store.dart';
import 'browser_storage_backend.dart';
import 'browser_store_stub.dart'
    if (dart.library.js_interop) 'browser_store_web.dart' as platform;
import 'memory_storage_backend.dart';
import 'storage_backend.dart';
import 'storage_capabilities.dart';

/// A storage backend plus the flags the caller must read.
final class OpenedStorage {
  OpenedStorage(this.storage, this.capabilities);
  final StorageBackend storage;
  final StorageCapabilities capabilities;
}

/// Opens [name] in OPFS, then IndexedDB. A missing interface returns memory
/// storage and [StoragePlacement.memory]. Neither placement promises that
/// sync survives power loss.
///
/// [probe] replaces the platform lookup. Tests pass a [MemoryBrowserByteStore]
/// or null. A null result is the missing-interface path.
Future<OpenedStorage> openBrowserStorage({
  required String name,
  Future<BrowserByteStore?> Function()? probe,
}) async {
  if (name.isEmpty ||
      name.contains('\u0000') ||
      name.contains('/') ||
      name.contains('\\')) {
    throw ArgumentError.value(name, 'name', 'Invalid browser storage name');
  }
  final store =
      probe == null ? await platform.openPlatformBrowserStore() : await probe();
  if (store == null) {
    return OpenedStorage(MemoryStorageBackend(), StorageCapabilities.memory);
  }
  return OpenedStorage(await BrowserStorageBackend.open(store, name),
      StorageCapabilities.browser);
}
