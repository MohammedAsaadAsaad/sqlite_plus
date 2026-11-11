part of '../sqlite_plus_orm.dart';

enum OrmImportDuplicates { reject, keepFirst, keepLast }

enum OrmImportEmptyValues { overwrite, keepExisting }

final class OrmImportIssue {
  const OrmImportIssue(this.inputIndex, this.code, this.message,
      {this.error = true});
  final int inputIndex;
  final String code, message;
  final bool error;
}

/// Input preparation, not a promise about current DB inserted/updated counts.
/// Plans capture encoded values; source data is resolved atomically at apply.
final class OrmImportPlan<T> {
  OrmImportPlan._(
      this._set,
      this.inputCount,
      this._rows,
      this._keys,
      this._fields,
      this.emptyValues,
      this._collations,
      List<OrmImportIssue> issues)
      : issues = List.unmodifiable(issues);
  final DbSet<T> _set;
  final List<String> _collations;
  final List<Map<String, Object?>> _rows;
  final List<Column<T, dynamic>> _keys, _fields;
  final int inputCount;
  final OrmImportEmptyValues emptyValues;
  final List<OrmImportIssue> issues;
  bool _applying = false, _applied = false;
  int get readyCount => _rows.length;
  int get rejectedCount =>
      issues.where((i) => i.error).map((i) => i.inputIndex).toSet().length;
  int get droppedCount =>
      issues.where((i) => !i.error).map((i) => i.inputIndex).toSet().length;
  bool get canApply => issues.every((i) => !i.error) && !_applied && !_applying;

  Future<OrmWriteResult> apply(
      {int batchSize = 200,
      List<Column<T, dynamic>> returning = const []}) async {
    if (!canApply) {
      throw const OrmStateException(
          'Import has unresolved errors, is active or already applied');
    }
    _applying = true;
    try {
      final result = await _set._upsertMany(<T>[],
          conflictOn: _keys,
          update: _fields,
          returning: returning,
          batchSize: batchSize,
          encoded: _rows,
          expectedCollations: _collations,
          keepEmpty: emptyValues == OrmImportEmptyValues.keepExisting);
      _applied = true;
      return result;
    } finally {
      _applying = false;
    }
  }
}

extension OrmImports<T> on DbSet<T> {
  /// Callers parse/map CSV/JSON/etc to entities. Null or empty text preserves
  /// stored fields on conflict only when keepExisting is explicitly selected.
  /// NOCASE/RTRIM duplicate identity is resolved by SQLite, not Dart equality.
  Future<OrmImportPlan<T>> prepareImport(Iterable<T> entities,
      {required List<Column<T, dynamic>> conflictOn,
      required List<Column<T, dynamic>> update,
      OrmImportDuplicates duplicates = OrmImportDuplicates.reject,
      OrmImportEmptyValues emptyValues = OrmImportEmptyValues.overwrite,
      String? Function(T entity)? validate}) {
    try {
      _writeType(type);
      final keys = _projection(type, conflictOn),
          fields = _projection(type, update);
      if (keys.isEmpty ||
          fields.isEmpty ||
          fields.any((c) =>
              c.keyOrder != null ||
              c.generated ||
              c.version ||
              keys.contains(c))) {
        throw const OrmMappingException(
            'Import requires conflict keys and writable non-key/non-version update fields');
      }
      context._checkTrackingMutable();
      final rows = <int, Map<String, Object?>>{};
      final issues = <OrmImportIssue>[];
      var count = 0;
      for (final entity in entities) {
        final index = count++;
        if (count > 10000 || count * keys.length > 20000) {
          throw RangeError('Import exceeds 10000 rows / 20000 key binds');
        }
        try {
          final reason = validate?.call(entity);
          if (reason != null) {
            issues.add(OrmImportIssue(index, 'validation', reason));
            continue;
          }
          final row = _copyOrmRow(type.encode(entity));
          if (keys.any((c) => row[c.sqlName] == null)) {
            issues.add(OrmImportIssue(
                index, 'nullKey', 'Conflict keys cannot be NULL'));
          } else {
            rows[index] = row;
          }
        } catch (error) {
          issues.add(OrmImportIssue(index, 'invalidValue',
              'Validation/encoding failed: ${error.runtimeType}'));
        }
      }
      return context._run(() async {
        final collations = await context._uniqueTarget(type, keys);
        if (rows.length > 1) {
          final parameters = <Object?>[];
          final values = [
            for (final entry in rows.entries)
              '(${entry.key},${keys.map((c) {
                parameters.add(copyOrmValue(entry.value[c.sqlName]));
                return '?';
              }).join(',')})'
          ];
          final names = [
            for (var i = 0; i < keys.length; i++) quoteIdentifier('_k$i')
          ];
          final groups = [
            for (var i = 0; i < keys.length; i++)
              '${names[i]} COLLATE ${quoteIdentifier(collations[i])}'
          ];
          final repeated = await context.connection.query(
              'WITH ${quoteIdentifier('_import')} (${quoteIdentifier('_i')},${names.join(',')}) AS (VALUES ${values.join(',')}) SELECT group_concat(${quoteIdentifier('_i')}) FROM ${quoteIdentifier('_import')} GROUP BY ${groups.join(',')} HAVING count(*)>1',
              parameters);
          for (final raw in repeated.rows) {
            final indices = (raw.single as String)
                .split(',')
                .map(int.parse)
                .toList()
              ..sort();
            final kept = duplicates == OrmImportDuplicates.keepFirst
                ? indices.first
                : indices.last;
            for (final i in indices) {
              if (duplicates != OrmImportDuplicates.reject && i == kept) {
                continue;
              }
              rows.remove(i);
              issues.add(OrmImportIssue(
                  i, 'duplicate', 'Repeated input conflict key',
                  error: duplicates == OrmImportDuplicates.reject));
            }
          }
        }
        issues.sort((a, b) => a.inputIndex.compareTo(b.inputIndex));
        return OrmImportPlan._(this, count, rows.values.toList(), keys, fields,
            emptyValues, collations, issues);
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }
}
