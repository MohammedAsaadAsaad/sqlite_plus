part of 'database.dart';

/// View metadata is available during preparation; rows are evaluated only when
/// an execution path consumes the relation. A failed evaluation is never cached.
final class _DeferredRelationRows extends ListBase<RowValues> {
  _DeferredRelationRows(this._evaluate);
  final List<RowValues> Function() _evaluate;
  List<RowValues>? _rows;
  bool _evaluating = false;

  List<RowValues> get _values {
    if (_rows != null) return _rows!;
    if (_evaluating) throw const SqlException('Circular view evaluation');
    _evaluating = true;
    try {
      return _rows = _evaluate();
    } finally {
      _evaluating = false;
    }
  }

  @override
  int get length => _values.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only view rows');
  @override
  RowValues operator [](int index) => _values[index];
  @override
  void operator []=(int index, RowValues value) =>
      throw UnsupportedError('Read-only view rows');
}
