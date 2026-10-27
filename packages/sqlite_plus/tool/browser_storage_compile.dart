import 'package:sqlite_plus/sqlite_plus.dart';

/// Compile-only entry. Running it is not a browser test.
Future<void> main() async {
  final opened = await openBrowserStorage(name: 'compile-check');
  if (opened.capabilities.durabilityPromised) {
    throw StateError('Browser storage must not promise power-loss durability');
  }
}
