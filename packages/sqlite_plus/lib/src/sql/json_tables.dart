import 'json_functions.dart';
import 'tokenizer.dart';
import 'virtual_table.dart';

void registerJsonTableFunctions(VirtualTableRegistry registry) {
  registry.register(_JsonModule('json_each', false));
  registry.register(_JsonModule('json_tree', true));
}

final class _JsonModule extends VirtualTableModule {
  _JsonModule(this.name, this.tree);
  @override
  final String name;
  final bool tree;
  @override
  List<String> get columns =>
      const ['key', 'value', 'type', 'atom', 'id', 'parent', 'fullkey', 'path'];
  @override
  List<String> get hiddenColumns => const ['json', 'root'];
  @override
  bool get eponymous => true;
  @override
  void bestIndex(VirtualTableIndexPlan plan) {
    final seen = <int>{};
    for (var index = 0; index < plan.constraints.length; index++) {
      final constraint = plan.constraints[index];
      if (constraint.operator == '=' &&
          (constraint.column == 8 || constraint.column == 9) &&
          seen.add(constraint.column)) {
        plan.use(index);
      }
    }
  }

  @override
  VirtualTableCursor xOpen(String table) => _JsonCursor(tree);
}

final class _JsonCursor extends VirtualTableCursor {
  _JsonCursor(this._tree);
  final bool _tree;
  List<Object?> _arguments = const [];
  List<VirtualTableConstraint> _constraints = const [];
  List<List<Object?>> _rows = const [];
  var _index = 0;
  var _closed = false;

  void _live() {
    if (_closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void applyArguments(List<Object?> arguments) {
    _live();
    _arguments = arguments;
  }

  @override
  void applyConstraints(List<VirtualTableConstraint> constraints) {
    _live();
    _constraints = constraints;
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    Object? json;
    Object? root;
    var hasJson = false;
    var hasRoot = false;
    if (_arguments.isNotEmpty) {
      json = _arguments[0];
      hasJson = true;
    }
    if (_arguments.length > 1) {
      root = _arguments[1];
      hasRoot = true;
    }
    for (final constraint in _constraints) {
      if (constraint.operator != '=') continue;
      if (constraint.column == 8) {
        json = constraint.value;
        hasJson = true;
      } else if (constraint.column == 9) {
        root = constraint.value;
        hasRoot = true;
      }
    }
    _rows = hasJson
        ? jsonTableRows(json, root: root, hasRoot: hasRoot, tree: _tree)
        : const [];
    _index = 0;
  }

  @override
  void next() {
    _live();
    if (_index < _rows.length) _index++;
  }

  @override
  bool get eof {
    _live();
    return _index >= _rows.length;
  }

  @override
  Object? column(int index) {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    final row = _rows[_index];
    if (index < 0 || index >= row.length) {
      throw const SqlException('Virtual table column index out of range');
    }
    return row[index];
  }

  @override
  BigInt get rowid {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    return BigInt.from(_index + 1);
  }

  @override
  void close() {
    _closed = true;
    _rows = const [];
  }
}
