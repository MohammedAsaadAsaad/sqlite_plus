import 'dart:convert';
import 'dart:io';

/// One saved table position on the schema graph.
class GraphPoint {
  const GraphPoint(this.x, this.y);

  final double x;
  final double y;

  Map<String, Object> toJson() => {'x': x, 'y': y};

  static GraphPoint? fromJson(Object? value) {
    if (value is! Map) return null;
    final x = value['x'];
    final y = value['y'];
    if (x is! num || y is! num) return null;
    if (!x.isFinite || !y.isFinite) return null;
    return GraphPoint(x.toDouble(), y.toDouble());
  }
}

/// Card positions for databases this app has opened.
///
/// The file is `graphs.json` in the app data folder. Each entry is keyed by
/// the database path, not by the image bytes. A memory database has no path
/// and is not stored. Tables that another program removed are dropped the
/// next time this file is opened. Tables that were added receive [placed].
class GraphLayoutStore {
  GraphLayoutStore.memory() : file = null;

  GraphLayoutStore.file(this.file);

  /// `graphs.json`. Null keeps the maps in memory for tests.
  final File? file;

  final Map<String, Map<String, GraphPoint>> _layouts = {};
  var _loaded = false;
  Future<void> _tail = Future<void>.value();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final target = file;
    if (target == null || !target.existsSync()) return;
    try {
      final decoded = jsonDecode(target.readAsStringSync());
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final tables = entry.value;
        if (key is! String || key.isEmpty || tables is! Map) continue;
        final points = <String, GraphPoint>{};
        for (final table in tables.entries) {
          final name = table.key;
          if (name is! String || name.isEmpty) continue;
          final point = GraphPoint.fromJson(table.value);
          if (point != null) points[name] = point;
        }
        if (points.isNotEmpty) _layouts[key] = points;
      }
    } on FormatException {
      _layouts.clear();
    } on FileSystemException {
      _layouts.clear();
    }
  }

  /// Positions stored for [key]. Empty when [key] is null or unknown.
  Map<String, GraphPoint> read(String? key) {
    if (key == null || key.isEmpty) return const {};
    final saved = _layouts[key];
    if (saved == null) return const {};
    return Map<String, GraphPoint>.from(saved);
  }

  /// Replaces the positions stored for [key]. A null key is ignored.
  Future<void> save(String? key, Map<String, GraphPoint> positions) {
    if (key == null || key.isEmpty) return Future<void>.value();
    _layouts[key] = {
      for (final entry in positions.entries)
        if (entry.key.isNotEmpty &&
            entry.value.x.isFinite &&
            entry.value.y.isFinite)
          entry.key: entry.value,
    };
    final write = _tail.then((_) => _write());
    _tail = write.then((_) {}, onError: (_) {});
    return write;
  }

  Future<void> _write() async {
    final target = file;
    if (target == null) return;
    try {
      final parent = target.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final encoded = <String, Object>{};
      for (final entry in _layouts.entries) {
        encoded[entry.key] = {
          for (final table in entry.value.entries)
            table.key: table.value.toJson(),
        };
      }
      target.writeAsStringSync(jsonEncode(encoded));
    } on FileSystemException {
      return;
    }
  }
}

/// Keeps a saved point when that table still exists.
///
/// [placed] is the automatic layout for the tables that exist now. A renamed
/// or deleted table is absent from [placed], so it leaves the result. A new
/// table uses the point from [placed].
Map<String, GraphPoint> mergeGraphLayout({
  required Map<String, GraphPoint> saved,
  required Map<String, GraphPoint> placed,
}) {
  return {
    for (final name in placed.keys) name: saved[name] ?? placed[name]!,
  };
}
