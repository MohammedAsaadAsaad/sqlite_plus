import 'dart:async';
import 'tokenizer.dart';
import 'values.dart';
import 'date_functions.dart';

/// A fresh aggregate instance is created for each SQL group/frame.
abstract class SqlAggregate {
  void step(List<Object?> arguments);
  Object? finish();
}

final class RegisteredSqlFunction {
  RegisteredSqlFunction(
      this.name, this.argumentCount, this.scalar, this.aggregate);
  final String name;
  final int argumentCount;
  final Object? Function(List<Object?>)? scalar;
  final SqlAggregate Function()? aggregate;
  bool accepts(int count) => argumentCount == -1 || count == argumentCount;
  Object? invoke(List<Object?> values) {
    try {
      return sqlValue(scalar!(List.unmodifiable(values.map(sqlValue))));
    } on SqlException {
      rethrow;
    } catch (_) {
      throw SqlException('User function $name failed');
    }
  }
}

/// Connection-local synchronous Pure Dart functions. Callbacks receive SQL values
/// (BigInt, double, String, Uint8List or null); return values use binding rules.
final class SqlFunctionRegistry {
  static final Object _zoneKey = Object();
  final Map<String, Map<int, RegisteredSqlFunction>> _functions = {};
  void registerScalar(String name, int argumentCount,
          Object? Function(List<Object?>) callback) =>
      _register(RegisteredSqlFunction(name, argumentCount, callback, null));
  void registerAggregate(
          String name, int argumentCount, SqlAggregate Function() factory) =>
      _register(RegisteredSqlFunction(name, argumentCount, null, factory));
  void _register(RegisteredSqlFunction definition) {
    if (definition.name.isEmpty ||
        definition.name.contains('\u0000') ||
        definition.argumentCount < -1 ||
        definition.argumentCount > 1000) {
      throw ArgumentError('Invalid SQL function signature');
    }
    _functions.putIfAbsent(
            asciiLower(definition.name), () => {})[definition.argumentCount] =
        definition;
  }

  void unregister(String name, int argumentCount) =>
      _functions[asciiLower(name)]?.remove(argumentCount);
  static SqlFunctionRegistry? get current =>
      Zone.current[_zoneKey] as SqlFunctionRegistry?;
  T run<T>(T Function() action) => runZoned(action, zoneValues: {
        sqlStatementTimeKey: identical(current, this)
            ? Zone.current[sqlStatementTimeKey] ?? DateTime.now().toUtc()
            : DateTime.now().toUtc(),
        _zoneKey: this,
      });
  static RegisteredSqlFunction? resolve(String name, int count) {
    final overloads = current?._functions[asciiLower(name)];
    return overloads?[count] ?? overloads?[-1];
  }
}
