import 'dart:async';
import 'dart:typed_data';

import '../btree/btree_reader.dart';
import 'catalog.dart';
import 'values.dart';
import 'parser.dart';
import 'tokenizer.dart';

/// A Pure Dart virtual-table module. There is no C ABI and no native entry
/// points. [read] returns one list per row, in [columns] order.
///
/// [xCreate] runs for `CREATE VIRTUAL TABLE`. [xConnect] and [xDisconnect]
/// bracket each statement that reads the table. [xDestroy] runs for `DROP TABLE`.
abstract class VirtualTableModule {
  String get name;
  List<String> get columns;

  /// Whole-result helper used by the default cursor. A module that overrides
  /// [xOpen] does not need this.
  List<List<Object?>> read(String table, List<String> arguments) {
    throw const SqlException('Virtual table module did not implement read');
  }

  VirtualTableCursor xOpen(String table) => _MaterializedCursor(this);
  void xCreate(String table, List<String> arguments) {}
  void xConnect(String table, List<String> arguments) {}
  void xDisconnect(String table) {}
  void xDestroy(String table) {}
}

/// One scan position. Methods throw after [close].
abstract class VirtualTableCursor {
  void filter(String table, List<String> arguments);
  void next();
  bool get eof;
  Object? column(int index);
  BigInt get rowid;
  void close();
}

final class _MaterializedCursor implements VirtualTableCursor {
  _MaterializedCursor(this._module);
  final VirtualTableModule _module;
  var _closed = false;
  var _index = 0;
  List<List<Object?>> _rows = const [];

  void _live() {
    if (_closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    _rows = _module.read(table, arguments);
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

void invokeVirtualTableCallback(String action, void Function() body) {
  try {
    body();
  } on SqlException {
    rethrow;
  } catch (_) {
    throw SqlException('Virtual table $action failed');
  }
}

/// Connection-local modules. Published on the function-registry zone while a
/// statement runs.
final class VirtualTableRegistry {
  static final Object _zoneKey = Object();
  final Map<String, VirtualTableModule> _modules = {};

  static VirtualTableRegistry? get current =>
      Zone.current[_zoneKey] as VirtualTableRegistry?;

  void register(VirtualTableModule module) {
    final key = asciiLower(module.name);
    if (module.name.isEmpty ||
        module.name.contains('\u0000') ||
        key.startsWith('sqlite_')) {
      throw ArgumentError('Invalid virtual table module name');
    }
    if (module.columns.isEmpty || module.columns.length > 1000) {
      throw ArgumentError('Invalid virtual table column count');
    }
    final seen = <String>{};
    for (final column in module.columns) {
      if (column.isEmpty ||
          column.contains('\u0000') ||
          !seen.add(asciiLower(column))) {
        throw ArgumentError('Invalid virtual table column');
      }
    }
    if (_modules.containsKey(key)) {
      throw ArgumentError('Virtual table module already registered');
    }
    _modules[key] = module;
  }

  VirtualTableModule? find(String name) => _modules[asciiLower(name)];

  static T run<T>(VirtualTableRegistry registry, T Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: registry});
}

/// Parsed `CREATE VIRTUAL TABLE ... USING module(...)` text.
final class VirtualTableDeclaration {
  VirtualTableDeclaration(this.name, this.module, this.arguments,
      {this.ifNotExists = false});
  final String name;
  final String module;
  final List<String> arguments;
  final bool ifNotExists;

  static bool isVirtual(String? sql) {
    if (sql == null) return false;
    final parser = SqlParser(sql);
    return parser.take('CREATE') && parser.take('VIRTUAL');
  }

  static VirtualTableDeclaration parse(String sql) {
    final parser = SqlParser(sql);
    parser.require('CREATE');
    parser.require('VIRTUAL');
    parser.require('TABLE');
    var ifNotExists = false;
    if (parser.take('IF')) {
      parser.require('NOT');
      parser.require('EXISTS');
      ifNotExists = true;
    }
    final name = parser.identifier();
    if (parser.take('(')) {
      throw const SqlException(
          'Virtual table column declarations are not supported yet');
    }
    parser.require('USING');
    final module = parser.identifier();
    final arguments = <String>[];
    if (parser.take('(')) {
      if (!parser.take(')')) {
        do {
          arguments.add(_argument(parser));
        } while (parser.take(','));
        parser.require(')');
      }
    }
    parser.finish();
    return VirtualTableDeclaration(name, module, arguments,
        ifNotExists: ifNotExists);
  }

  static String _argument(SqlParser parser) {
    final token = parser.current;
    if (token.kind == SqlTokenKind.string ||
        token.kind == SqlTokenKind.identifier ||
        token.kind == SqlTokenKind.number) {
      parser.position++;
      return token.text;
    }
    throw SqlException('Unsupported virtual table argument', token.offset);
  }
}

/// Materializes module rows as synthetic table records. The module is resolved
/// from the connection that is executing the statement.
abstract final class VirtualTableRows {
  static const maximumRows = 100000;

  static List<BtreeRecord> records(CatalogTable table) {
    final moduleName = table.virtualModule;
    if (moduleName == null) {
      throw const SqlException('Not a virtual table');
    }
    final module = VirtualTableRegistry.current?.find(moduleName);
    if (module == null) {
      throw SqlException('No such module: $moduleName');
    }
    invokeVirtualTableCallback(
        'xConnect', () => module.xConnect(table.name, table.virtualArguments));
    final cursor = module.xOpen(table.name);
    final records = <BtreeRecord>[];
    Object? failure;
    try {
      try {
        cursor.filter(table.name, table.virtualArguments);
        while (!cursor.eof) {
          if (records.length >= maximumRows) {
            throw const SqlException('Virtual table row limit exceeded');
          }
          final rowid = cursor.rowid;
          final values = [
            for (var index = 0; index < module.columns.length; index++)
              _value(cursor.column(index))
          ];
          records.add(BtreeRecord.synthetic(rowid, values));
          cursor.next();
        }
      } on SqlException catch (error) {
        failure = error;
      } catch (_) {
        failure = SqlException('Virtual table module $moduleName failed');
      }
    } finally {
      try {
        cursor.close();
      } on SqlException catch (error) {
        failure ??= error;
      } catch (_) {
        failure ??= const SqlException('Virtual table cursor close failed');
      }
      try {
        module.xDisconnect(table.name);
      } on SqlException catch (error) {
        failure ??= error;
      } catch (_) {
        failure ??= const SqlException('Virtual table xDisconnect failed');
      }
    }
    if (failure != null) throw failure;
    return records;
  }

  static Object? _value(Object? value) {
    if (value == null || value is BigInt || value is String) return value;
    if (value is int) return BigInt.from(value);
    if (value is double) return value.isNaN ? null : value;
    if (value is Uint8List) return Uint8List.fromList(value);
    throw const SqlException(
        'Virtual table module returned an unsupported value');
  }
}
