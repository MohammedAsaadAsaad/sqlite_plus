import 'dart:typed_data';

/// One named blob in a browser origin. Implementations do not promise that a
/// completed write survives power loss.
abstract interface class BrowserByteStore {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List bytes);
}

/// In-process stand-in for OPFS or IndexedDB. Tests use it when no browser is
/// running. It is not the browser and it is not durable.
final class MemoryBrowserByteStore implements BrowserByteStore {
  final Map<String, Uint8List> _files = {};

  @override
  Future<Uint8List?> read(String name) async {
    final bytes = _files[name];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    _files[name] = Uint8List.fromList(bytes);
  }
}
