import 'dart:async';
import 'dart:typed_data';

import 'fts_text.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'virtual_table.dart';

/// Rows preloaded from shadow tables before a synchronous virtual scan.
final class ShadowTable {
  ShadowTable(this.columns, this.rows, {this.rowidAlias});
  final List<String> columns;
  final String? rowidAlias;
  final List<ShadowRow> rows;

  Object? value(ShadowRow row, String name) {
    if (rowidAlias != null && asciiLower(rowidAlias!) == asciiLower(name)) {
      return row.rowId;
    }
    final index =
        columns.indexWhere((column) => asciiLower(column) == asciiLower(name));
    if (index < 0 || index >= row.values.length) return null;
    final stored = row.values[index];
    return stored ?? (rowidAlias != null && index == 0 ? row.rowId : stored);
  }
}

final class ShadowRow {
  ShadowRow(this.rowId, this.values);
  final BigInt rowId;
  final List<Object?> values;
}

final Object searchSnapshotKey = Object();

final class SearchSnapshot {
  SearchSnapshot(Map<String, ShadowTable> tables)
      : tables = {
          for (final entry in tables.entries) asciiLower(entry.key): entry.value
        };
  static const empty = SearchSnapshot._empty();
  const SearchSnapshot._empty() : tables = const {};
  final Map<String, ShadowTable> tables;

  static SearchSnapshot get current {
    final value = Zone.current[searchSnapshotKey];
    return value is SearchSnapshot ? value : empty;
  }

  ShadowTable? table(String name) => tables[asciiLower(name)];
}

final _sessions = Expando<FtsSession>('fts-session');

final class FtsSession {
  final Map<String, FtsTableState> tables = {};
}

final class FtsTableState {
  FtsTableState(this.spec, this.documents);
  final Fts5Spec spec;
  final Map<BigInt, FtsDocument> documents;
  FtsQuery? query;
  int? column;
  FtsBm25? bm25;
  final Map<BigInt, List<FtsInst>> instances = {};
  final Map<BigInt, double> scores = {};
}

FtsSession ftsSession() {
  final registry = VirtualTableRegistry.current;
  if (registry == null) return FtsSession();
  return _sessions[registry] ??= FtsSession();
}

Object? ftsMatchValue(String? columnName, Object? pattern, Object? rowid) {
  final text = ftsPatternText(pattern);
  final state = _stateFor(columnName);
  if (state == null || text == null || rowid is! BigInt) return BigInt.zero;
  final document = state.documents[rowid];
  if (document == null) return BigInt.zero;
  final query =
      parseFtsQuery(text, state.spec.tokenizer, state.spec.visibleNames);
  final column = _column(state, columnName);
  return boolean(query.matches(document, column: column));
}

Object? ftsAuxiliary(String function, String? tableName,
    List<Object?> arguments, Object? rowid) {
  final state = _stateFor(tableName);
  if (state == null || rowid is! BigInt) {
    throw SqlException(
        'unable to use function $function in the requested context');
  }
  if (state.query == null) {
    if (function == 'bm25') return null;
    throw SqlException(
        'unable to use function $function in the requested context');
  }
  final document = state.documents[rowid];
  if (document == null) return null;
  final display = FtsDocument(
      document.rowId,
      document.texts,
      [
        for (var i = 0; i < document.texts.length; i++)
          document.texts[i] == null
              ? document.tokens[i]
              : state.spec.tokenizer.tokenize(document.texts[i]!)
      ],
      document.unindexed);
  final instances = state.instances[rowid] ?? const <FtsInst>[];
  if (function == 'bm25') {
    final weights = [for (final argument in arguments) _weight(argument)];
    return state.bm25?.score(display, instances, weights) ?? 0.0;
  }
  final column = arguments.isEmpty ? 0 : _int(arguments[0]);
  final open = arguments.length > 1 ? _string(arguments[1]) : '';
  final close = arguments.length > 2 ? _string(arguments[2]) : '';
  if (function == 'highlight') {
    if (column < 0 || column >= display.texts.length) return '';
    return ftsHighlight(display.texts[column], display.tokens[column],
        instances, column, open, close);
  }
  final ellipsis = arguments.length > 3 ? _string(arguments[3]) : '';
  final tokens = arguments.length > 4 ? _int(arguments[4]) : 15;
  return ftsSnippet(display, instances, column, open, close, ellipsis, tokens);
}

String? ftsPatternText(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is BigInt || value is int) return value.toString();
  if (value is double) return sqlRealText(value);
  if (value is Uint8List) return null;
  return value.toString();
}

FtsTableState? _stateFor(String? name) {
  final session = ftsSession();
  if (name != null) {
    final direct = session.tables[asciiLower(name)];
    if (direct != null) return direct;
    for (final state in session.tables.values) {
      if (state.spec.visibleNames
          .any((column) => asciiLower(column) == asciiLower(name))) {
        return state;
      }
    }
  }
  if (session.tables.length == 1) return session.tables.values.single;
  return null;
}

int? _column(FtsTableState state, String? name) {
  if (name == null) return state.column;
  if (asciiLower(name) == asciiLower(state.spec.table)) return state.column;
  final index = state.spec.visibleNames
      .indexWhere((column) => asciiLower(column) == asciiLower(name));
  return index < 0 ? state.column : index;
}

double _weight(Object? value) {
  if (value is double) return value;
  if (value is BigInt) return value.toDouble();
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 1;
  return 1;
}

int _int(Object? value) {
  if (value is BigInt) return value.toInt();
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String _string(Object? value) => value == null ? '' : value.toString();
