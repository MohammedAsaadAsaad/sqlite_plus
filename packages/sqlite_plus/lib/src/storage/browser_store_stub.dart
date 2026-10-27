import 'browser_byte_store.dart';

/// VM and other targets without `dart:js_interop`. The browser interface is
/// absent, so the opener falls back to memory.
Future<BrowserByteStore?> openPlatformBrowserStore() async => null;
