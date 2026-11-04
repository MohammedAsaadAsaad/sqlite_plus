import 'package:flutter/services.dart';

/// A database handed to the app by the phone's open-with screen.
class OpenedFile {
  const OpenedFile({
    required this.name,
    required this.bytes,
    this.location,
  });

  final String name;
  final Uint8List bytes;
  final String? location;
}

/// Android view intents. Desktop and tests have no implementation.
class LaunchBridge {
  static const channel = MethodChannel('dev.sqliteplus.browser/files');

  static Future<OpenedFile?> takeLaunch() async {
    try {
      final raw = await channel.invokeMethod<dynamic>('takeLaunch');
      return decodeOpened(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static void listen(Future<void> Function(OpenedFile file) onOpened) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'opened') return;
      final file = decodeOpened(call.arguments);
      if (file != null) await onOpened(file);
    });
  }

  /// Android app files directory. Desktop and tests have no implementation.
  static Future<String?> documents() async {
    try {
      final path = await channel.invokeMethod<String>('documents');
      if (path == null || path.isEmpty) return null;
      return path;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<Uint8List?> readLocation(String location) async {
    try {
      final raw = await channel.invokeMethod<dynamic>('read', {
        'location': location,
      });
      if (raw is Uint8List) return raw;
      if (raw is List) return Uint8List.fromList(raw.cast<int>());
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

OpenedFile? decodeOpened(Object? raw) {
  if (raw is! Map) return null;
  final name = raw['name'];
  final bytes = raw['bytes'];
  final location = raw['location'];
  final data = _bytes(bytes);
  if (data == null || data.isEmpty) return null;
  return OpenedFile(
    name: name is String && name.trim().isNotEmpty
        ? name.trim()
        : 'database.sqlite',
    bytes: data,
    location: location is String && location.isNotEmpty ? location : null,
  );
}

Uint8List? _bytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is List) return Uint8List.fromList(value.cast<int>());
  return null;
}
