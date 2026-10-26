part of 'database.dart';

/// A prepared execution. Metadata is available before any row callback runs;
/// advancing the iterator resumes evaluation after the preceding consumer write.
final class _QueryExecution {
  _QueryExecution(List<String> columns, this.rows, List<String> affinities,
      List<String> declaredTypes, List<String> collations,
      {this.skipRows})
      : columns = List.unmodifiable(columns),
        columnAffinities = List.unmodifiable(affinities),
        columnDeclaredTypes = List.unmodifiable(declaredTypes),
        columnCollations = List.unmodifiable(collations);
  final List<String> columns;
  final Iterable<List<Object?>> rows;
  final List<String> columnAffinities;
  final List<String> columnDeclaredTypes;
  final List<String> columnCollations;
  final Iterable<List<Object?>> Function(_QueryOffset)? skipRows;

  Iterable<List<Object?>> consume(_QueryOffset offset) sync* {
    if (skipRows != null) {
      yield* skipRows!(offset);
    } else {
      for (final row in rows) {
        if (offset.remaining > 0) {
          offset.remaining--;
        } else {
          yield row;
        }
      }
    }
  }

  QueryResult materialize({bool firstRowOnly = false}) => QueryResult(
      columns,
      (firstRowOnly ? rows.take(1) : rows).toList(),
      columnAffinities,
      columnDeclaredTypes,
      columnCollations);
}

final class _QueryOffset {
  _QueryOffset(this.remaining);
  int remaining;
}

/// Scalar/EXISTS consumers impose one output row, while an explicit LIMIT
/// still determines whether there is an output and must retain its errors.
final class _ScalarSubqueryLimit extends Expr {
  _ScalarSubqueryLimit(this.original);
  final Expr? original;
  @override
  Iterable<Expr> get children => [if (original != null) original!];
  @override
  Object? evaluate(EvalContext context) {
    if (original == null) return BigInt.one;
    var value = original!.evaluate(context);
    if (value is String) value = numeric(value);
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      value = BigInt.from(value);
    }
    if (value is! BigInt || value.bitLength > 63) {
      throw const SqlException('LIMIT/OFFSET datatype mismatch');
    }
    return value == BigInt.zero ? BigInt.zero : BigInt.one;
  }
}
