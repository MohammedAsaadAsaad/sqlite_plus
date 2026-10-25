import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import 'catalog.dart';
import 'values.dart';

final class _IndexStatistics {
  _IndexStatistics(this.table, this.rows);
  final String table;
  // Total index entries followed by average entries per equal key prefix.
  final List<double> rows;
}

/// Optional planning hints only. No statistic is used to omit matching records.
/// Logical invalidity, stale names and duplicate rows fall back to heuristics;
/// malformed physical B-tree records still fail through the ordinary reader.
final class PlannerStatistics {
  PlannerStatistics._(this._indexes, this._tables);
  final Map<String, _IndexStatistics> _indexes;
  final Map<String, double> _tables;

  static Future<PlannerStatistics> read(
      ReadOnlyPager pager, DatabaseCatalog catalog) async {
    final entry = catalog.entries
        .where((entry) =>
            entry.type == 'table' && asciiLower(entry.name) == 'sqlite_stat1')
        .firstOrNull;
    if (entry == null) return PlannerStatistics._({}, {});
    final tables = {
      for (final entry
          in catalog.entries.where((entry) => entry.type == 'table'))
        asciiLower(entry.name)
    };
    final owners = {
      for (final entry
          in catalog.entries.where((entry) => entry.type == 'index'))
        asciiLower(entry.name): asciiLower(entry.tableName)
    };
    final indexes = <String, _IndexStatistics>{};
    final rowCounts = <String, double>{};
    final duplicateIndexes = <String>{};
    final duplicateTables = <String>{};
    final seenIndexes = <String>{};
    final seenTables = <String>{};
    await for (final record in BtreeReader(pager).scanTable(entry.rootPage)) {
      final row = record.values;
      if (row.length != 3 || row[0] is! String) continue;
      final table = asciiLower(row[0] as String);
      if (!tables.contains(table)) continue;
      if (row[1] == null) {
        if (!seenTables.add(table)) duplicateTables.add(table);
        final parsed = _parse(row[2]);
        if (parsed != null && parsed.length == 1) rowCounts[table] = parsed[0];
      } else if (row[1] is String) {
        final index = asciiLower(row[1] as String);
        if (owners[index] != table) continue;
        if (!seenIndexes.add(index)) duplicateIndexes.add(index);
        final parsed = _parse(row[2]);
        if (parsed != null && parsed.length > 1) {
          indexes[index] = _IndexStatistics(table, parsed);
        }
      }
    }
    indexes.removeWhere((name, _) => duplicateIndexes.contains(name));
    rowCounts.removeWhere((name, _) => duplicateTables.contains(name));
    return PlannerStatistics._(indexes, rowCounts);
  }

  static List<double>? _parse(Object? value) {
    if (value is! String || value.length > 65536) return null;
    final tokens = value.trim().split(RegExp(r'[\t\n\v\f\r ]+'));
    if (tokens.isEmpty || tokens.length > 2001) return null;
    final result = <double>[];
    for (final token in tokens) {
      if (!RegExp(r'^[0-9]+$').hasMatch(token)) {
        // Native flags do not change the prefix estimates used here.
        if (token == 'unordered' || token == 'noskipscan') continue;
        if (RegExp(r'^sz=[0-9]+$').hasMatch(token)) {
          continue;
        }
        return null;
      }
      if (token.length > 19) return null;
      final integer = BigInt.parse(token);
      if (integer > (BigInt.one << 63) - BigInt.one) return null;
      final number = integer.toDouble();
      if (result.isNotEmpty && number > result.last) return null;
      if (result.isNotEmpty && (number == 0) != (result.first == 0)) {
        return null;
      }
      result.add(number);
    }
    return result.isEmpty ? null : result;
  }

  double? estimate(String tableName, String indexName,
      {required int columns,
      required int equalities,
      required int rangeBounds,
      required bool unique}) {
    final table = asciiLower(tableName);
    final statistic = _indexes[asciiLower(indexName)];
    final matching = statistic != null &&
        statistic.table == table &&
        statistic.rows.length == columns + 1;
    double? total = _tables[table];
    for (final index
        in _indexes.values.where((index) => index.table == table)) {
      if (total == null || index.rows.first > total) total = index.rows.first;
    }
    if (total == null) return null;
    var rows = matching ? statistic.rows.first : total;
    if (unique && equalities == columns) return 1;
    if (equalities != 0) {
      if (matching) {
        rows = statistic.rows[equalities];
      } else {
        for (var i = 0; i < equalities; i++) {
          rows /= 10;
        }
      }
    }
    // One fourfold reduction per distinct lower/upper bound. STAT1 contains no
    // histogram from which to infer the actual distribution within a range.
    for (var i = 0; i < rangeBounds; i++) {
      rows /= 4;
    }
    return rows < 1 ? 1 : rows;
  }
}
