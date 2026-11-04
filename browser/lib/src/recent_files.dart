import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'launch_bridge.dart';

/// A database the app can open again.
class RecentFile {
  const RecentFile({
    required this.name,
    required this.opened,
    required this.copyPath,
    this.location,
  });

  final String name;
  final DateTime opened;

  /// A copy kept beside the recent list, used when [location] cannot be read.
  final String copyPath;

  /// A filesystem path or a `content:` URI. Null for a copy-only entry.
  final String? location;

  Map<String, Object?> toJson() => {
        'name': name,
        'opened': opened.toUtc().toIso8601String(),
        'copyPath': copyPath,
        'location': location,
      };

  static RecentFile? fromJson(Object? value) {
    if (value is! Map) return null;
    final name = value['name'];
    final opened = value['opened'];
    final copyPath = value['copyPath'];
    if (name is! String || opened is! String || copyPath is! String) {
      return null;
    }
    final location = value['location'];
    return RecentFile(
      name: name,
      opened: DateTime.tryParse(opened)?.toUtc() ?? DateTime.now().toUtc(),
      copyPath: copyPath,
      location: location is String && location.isNotEmpty ? location : null,
    );
  }
}

/// The short place shown under a recent name.
String recentPlace(RecentFile file) {
  final location = file.location;
  if (location == null || location.isEmpty) return 'Saved in the app';
  if (location.startsWith('content:')) return 'Phone storage';
  final parts =
      location.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty);
  final listed = parts.toList();
  if (listed.length < 2) return location;
  return listed[listed.length - 2];
}

/// Remembers the last databases this app opened.
class RecentStore extends ChangeNotifier {
  RecentStore.memory() : directory = null;

  RecentStore.directory(this.directory);

  /// Null keeps the list in memory for tests.
  final Directory? directory;

  List<RecentFile> files = const [];
  var _loaded = false;
  final Map<String, Uint8List> _memoryCopies = {};

  Future<void> load() async {
    if (_loaded) return;
    final root = directory;
    if (root == null) {
      _loaded = true;
      return;
    }
    final index = File('${root.path}/recent-files.json');
    if (index.existsSync()) {
      try {
        final decoded = jsonDecode(index.readAsStringSync());
        if (decoded is List) {
          files = [
            for (final item in decoded)
              if (RecentFile.fromJson(item) case final file?) file,
          ];
        }
      } on FormatException {
        files = const [];
      } on FileSystemException {
        files = const [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// Puts [name] at the top. [location] is preferred the next time it is read.
  Future<void> remember({
    required String name,
    required Uint8List bytes,
    String? location,
  }) async {
    await load();
    final clean = name.trim().isEmpty ? 'database.sqlite' : name.trim();
    final key = _key(location, clean);
    final copyPath = await _writeCopy(key, bytes);
    final next = RecentFile(
      name: clean,
      opened: DateTime.now().toUtc(),
      copyPath: copyPath,
      location: location,
    );
    final kept = [
      next,
      for (final file in files)
        if (_key(file.location, file.name) != key) file,
    ];
    final removed = kept.length > 12 ? kept.sublist(12) : const <RecentFile>[];
    files = kept.take(12).toList();
    for (final dropped in removed) {
      await _deleteCopy(dropped);
    }
    await _save();
    notifyListeners();
  }

  Future<void> forget(RecentFile file) async {
    await load();
    files = [
      for (final item in files)
        if (_key(item.location, item.name) != _key(file.location, file.name))
          item,
    ];
    await _deleteCopy(file);
    await _save();
    notifyListeners();
  }

  /// Bytes for [file]. A readable path or content URI wins over the copy.
  Future<Uint8List> read(RecentFile file) async {
    final location = file.location;
    if (location != null && location.startsWith('content:')) {
      final remote = await LaunchBridge.readLocation(location);
      if (remote != null && remote.isNotEmpty) return remote;
    }
    if (location != null && !location.startsWith('content:')) {
      final direct = File(location);
      if (direct.existsSync()) return direct.readAsBytesSync();
    }
    final memory = _memoryCopies[file.copyPath];
    if (memory != null) return memory;
    return File(file.copyPath).readAsBytesSync();
  }

  Future<void> _save() async {
    final root = directory;
    if (root == null) return;
    root.createSync(recursive: true);
    final index = File('${root.path}/recent-files.json');
    index.writeAsStringSync(jsonEncode([
      for (final file in files) file.toJson(),
    ]));
  }

  Future<String> _writeCopy(String key, Uint8List bytes) async {
    final root = directory;
    if (root == null) {
      final path = 'memory:$key';
      _memoryCopies[path] = bytes;
      return path;
    }
    final copy = File('${root.path}/copies/$key.sqlite');
    copy.parent.createSync(recursive: true);
    copy.writeAsBytesSync(bytes, flush: true);
    return copy.path;
  }

  Future<void> _deleteCopy(RecentFile file) async {
    if (files.any((item) => item.copyPath == file.copyPath)) return;
    _memoryCopies.remove(file.copyPath);
    final root = directory;
    if (root == null) return;
    final copy = File(file.copyPath);
    final copies = Directory('${root.path}/copies');
    if (!copy.path.startsWith('${copies.path}${Platform.pathSeparator}')) {
      return;
    }
    if (copy.existsSync()) copy.deleteSync();
  }

  String _key(String? location, String name) {
    final source =
        (location == null || location.isEmpty) ? 'name:$name' : location;
    var hash = 0x811c9dc5;
    for (final unit in source.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }
}
