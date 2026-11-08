part of '../sqlite_plus_branch.dart';

String _quote(String name) => '"${name.replaceAll('"', '""')}"';
String _hash(List<int> bytes) => sha256.convert(bytes).toString();
Object? _copyValue(Object? v) => v is Uint8List ? Uint8List.fromList(v) : v;
Map<String, Object?> _copyRow(Map<String, Object?> row) =>
    Map.unmodifiable(row.map((key, value) => MapEntry(key, _copyValue(value))));
Object _wire(Object? v) {
  if (v == null) return ['null'];
  // JS cannot distinguish an integral double from an int by runtime type.
  // Compare INTEGER/REAL by exact numeric value on every platform; images still
  // retain their SQLite storage classes. Non-numeric values stay type-sensitive.
  if (v is double && v.isFinite && v == v.truncateToDouble()) {
    v = BigInt.from(v);
  } else if (v is int) {
    v = BigInt.from(v);
  }
  if (v is BigInt) return ['integer', v.toString()];
  if (v is double && v.isFinite) return ['real', v == 0 ? 0.0 : v];
  if (v is String) return ['text', v];
  if (v is Uint8List) return ['blob', base64Encode(v)];
  throw const BranchException('Unsupported non-finite SQL value');
}

String _valueKey(Object? v) => jsonEncode(_wire(v));
bool _same(Object? a, Object? b) => _valueKey(a) == _valueKey(b);
bool _sameRow(Map<String, Object?>? a, Map<String, Object?>? b) =>
    a == null || b == null
        ? a == b
        : a.length == b.length &&
            a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));

/// Explicit resource budgets. These bound inputs, not the Dart process heap.
final class BranchLimits {
  const BranchLimits(
      {this.maxImageBytes = 32 * 1024 * 1024,
      this.maxRows = 10000,
      this.maxTables = 64,
      this.maxColumns = 128});
  final int maxImageBytes, maxRows, maxTables, maxColumns;
  int get maxArchiveBytes => maxImageBytes * 3 + 16384;
  void _validate() {
    if (maxImageBytes < 512 || maxRows < 1 || maxTables < 1 || maxColumns < 1) {
      throw ArgumentError('Positive branch limits and image >=512 required');
    }
  }
}

class BranchException implements Exception {
  const BranchException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'BranchException: $message';
}

final class BranchConflictException extends BranchException {
  BranchConflictException(this.preview)
      : super('Explicit conflict resolutions required');
  final BranchMergePreview preview;
}

/// A final row difference from the immutable base (not an operation history).
final class BranchRowDiff {
  BranchRowDiff._(this.table, Map<String, Object?> key,
      Map<String, Object?>? before, Map<String, Object?>? after)
      : _key = _copyRow(key),
        _before = before == null ? null : _copyRow(before),
        _after = after == null ? null : _copyRow(after);
  final String table;
  final Map<String, Object?> _key;
  final Map<String, Object?>? _before, _after;
  Map<String, Object?> get key => _copyRow(_key);
  Map<String, Object?>? get before =>
      _before == null ? null : _copyRow(_before);
  Map<String, Object?>? get after => _after == null ? null : _copyRow(_after);
  String get kind => _before == null
      ? 'insert'
      : _after == null
          ? 'delete'
          : 'update';
  List<String> get changedColumns =>
      List.unmodifiable((_after ?? _before!).keys.where((c) =>
          _before == null || _after == null || !_same(_before[c], _after[c])));
}

/// column==null denotes a row-level insert/delete conflict. All row getters copy BLOBs.
final class BranchConflict {
  BranchConflict._(this.id, this.kind, this.column, this.change, this._main);
  final String id, kind;
  final String? column;
  final BranchRowDiff change;
  final Map<String, Object?>? _main;
  String get table => change.table;
  Map<String, Object?> get key => change.key;
  Map<String, Object?>? get baseRow => change.before;
  Map<String, Object?>? get mainRow => _main == null ? null : _copyRow(_main);
  Map<String, Object?>? get branchRow => change.after;
  Object? get baseValue =>
      column == null ? baseRow : _copyValue(change._before?[column]);
  Object? get mainValue =>
      column == null ? mainRow : _copyValue(_main?[column]);
  Object? get branchValue =>
      column == null ? branchRow : _copyValue(change._after?[column]);
}

final class BranchResolution {
  const BranchResolution.useMain()
      : _kind = 'main',
        _value = null;
  const BranchResolution.useBranch()
      : _kind = 'branch',
        _value = null;
  BranchResolution.value(Object? value)
      : _kind = 'value',
        _value = _copyValue(value) {
    _wire(value);
  }
  final String _kind;
  final Object? _value;
}

final class BranchMergePreview {
  BranchMergePreview._(this._branchId, this._mainHash, this._branchHash,
      List<BranchRowDiff> changes, List<BranchConflict> conflicts)
      : changes = List.unmodifiable(changes),
        conflicts = List.unmodifiable(conflicts);
  final String _branchId, _mainHash, _branchHash;
  final List<BranchRowDiff> changes;
  final List<BranchConflict> conflicts;
}

final class BranchMergeResult {
  const BranchMergeResult(this.appliedRows, {this.alreadyMerged = false});
  final int appliedRows;
  final bool alreadyMerged;
}
