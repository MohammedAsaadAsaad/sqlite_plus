part of 'database.dart';

/// The bindings retained by a joined source group. Hidden qualified fields are
/// kept separate from visible wildcard slots so outer joins can null-extend the
/// whole group without losing the original table namespaces.
final class _JoinedGroup {
  _JoinedGroup(this.prefix);
  final String prefix;
  List<RowValues> rows = [];
  final aliases = <String>{};
  final declared = <String, CatalogColumn>{};
  final refs = <String, List<String>>{};
  final implicit = <String>{};
  final nestedImplicit = <String>{};
  final labels = <String, String>{};
  final star = <(String, String)>[];
  final sourceStars = <String, List<(String, String)>>{};
  final canonical = <String, String>{};
  final fieldOrder = <String>[];

  void materialize(String? alias) {
    // A nested joined subquery has no intrinsic rowid. Its children's implicit
    // rowids cannot be pulled through another materialization boundary.
    final removed = {
      for (final key in declared.keys)
        if (nestedImplicit.contains(canonical[key] ?? key)) key,
    };
    declared.removeWhere((key, _) => removed.contains(key));
    implicit.removeAll(removed);
    for (final entry in refs.entries.toList()) {
      entry.value.removeWhere(removed.contains);
      if (entry.value.isEmpty) refs.remove(entry.key);
    }
    fieldOrder.removeWhere(removed.contains);
    for (final row in rows) {
      row.removeWhere((key, _) => removed.contains(key));
    }
    final assigned = <String, String>{}, used = <String>{};
    String allocate(String key, String label) {
      final original = canonical[key] ?? key;
      if (assigned.containsKey(original)) return assigned[original]!;
      var candidate = label, suffix = 0;
      while (used.contains(asciiLower(candidate))) {
        candidate = '${label.replaceFirst(RegExp(r':\d+$'), '')}:${++suffix}';
      }
      used.add(asciiLower(candidate));
      assigned[original] = candidate;
      return candidate;
    }

    for (var i = 0; i < star.length; i++) {
      final (label, key) = star[i];
      star[i] = (allocate(key, label), key);
    }
    for (final key in fieldOrder) {
      allocate(key, labels[key] ?? declared[key]!.name);
    }
    for (final entry in declared.entries.toList()) {
      final key = entry.key, column = entry.value;
      final original = canonical[key] ?? key;
      if (assigned.containsKey(original)) labels[key] = assigned[original]!;
      declared[key] = CatalogColumn(column.name, column.declaredType,
          affinityOverride: column.affinity,
          collation: column.collation.isEmpty ? 'binary' : column.collation);
    }
    for (final entry in sourceStars.entries.toList()) {
      sourceStars[entry.key] = [
        for (final slot in entry.value)
          (assigned[canonical[slot.$2] ?? slot.$2] ?? slot.$1, slot.$2)
      ];
    }
    if (alias != null) {
      final name = asciiLower(alias);
      for (final entry in assigned.entries) {
        final key = '$name.${asciiLower(entry.value)}';
        // Original child qualifiers take precedence over a colliding group
        // alias, matching SQLite's source-name lookup order.
        if (declared.containsKey(key)) continue;
        final column = declared[entry.key]!;
        declared[key] = CatalogColumn(entry.value, column.declaredType,
            affinityOverride: column.affinity, collation: column.collation);
        labels[key] = entry.value;
        canonical[key] = entry.key;
        for (final row in rows) {
          row[key] = row[entry.key];
        }
      }
    }
    fieldOrder
      ..clear()
      ..addAll(assigned.keys);
  }
}
