import 'dart:typed_data';

import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'function_registry.dart';
import 'core_functions.dart';
import 'date_functions.dart';
import 'index_definition.dart' show sameExpression;
import 'expressions.dart';
import 'printf_functions.dart';
import 'percentile_functions.dart';
import 'json_functions.dart';

final class FunctionExpr extends Expr {
  FunctionExpr(this.name, this.arguments,
      {this.distinct = false,
      this.star = false,
      bool deferResolution = false,
      this.deferValidation = false})
      : registered = _registered(name, arguments.length) {
    // CREATE VIEW stores syntactically valid SQL. Function availability and
    // signatures are resolved when the stored query is later prepared.
    if (!deferResolution) _resolveSignature();
  }

  bool _signatureResolved = false;
  final bool deferValidation;
  void resolveSignature() => _resolveSignature();
  void _resolveSignature() {
    if (_signatureResolved) return;
    final range = registered == null
        ? _arities[key]
        : (registered!.argumentCount == -1
            ? (0, 1000)
            : (registered!.argumentCount, registered!.argumentCount));
    if (range == null) throw SqlException('No such function: $name');
    if (arguments.length < range.$1 ||
        arguments.length > range.$2 ||
        distinct && star ||
        distinct && isAggregate && arguments.length != 1) {
      throw SqlException('Invalid arguments to $name');
    }
    if (registered == null && key == 'likelihood') {
      final probability = arguments[1];
      if (probability is! Literal ||
          probability.value is! double ||
          (probability.value as double) < 0 ||
          (probability.value as double) > 1) {
        throw const SqlException(
            'second argument to likelihood() must be a constant between 0.0 and 1.0');
      }
    }
    _signatureResolved = true;
  }

  final RegisteredSqlFunction? registered;
  final String name;
  final List<Expr> arguments;
  final bool distinct;
  final bool star;
  static RegisteredSqlFunction? _registered(String name, int count) {
    final definition = SqlFunctionRegistry.resolve(name, count);
    // The pinned FTS extension installs its MATCH(2) error stub as a
    // connection-local exact overload, ahead of a user variadic overload.
    if (asciiLower(name) == 'match' &&
        count == 2 &&
        definition?.argumentCount == -1) {
      return null;
    }
    return definition;
  }

  Expr? filter;
  final List<OrderTerm> order = [];
  bool windowFunction = false;
  String get key => asciiLower(name);
  bool get isAggregate => registered != null
      ? registered!.aggregate != null
      : [
            'count',
            'sum',
            'total',
            'avg',
            'group_concat',
            'string_agg',
            'json_group_array',
            'jsonb_group_array',
            'json_group_object',
            'jsonb_group_object',
            ...percentileFunctionNames
          ].contains(key) ||
          ['min', 'max'].contains(key) && arguments.length == 1;
  @override
  Iterable<Expr> get children => [
        ...arguments,
        if (filter != null) filter!,
        ...order.map((t) => t.expression)
      ];
  @override
  bool get containsAggregate => isAggregate || super.containsAggregate;
  @override
  Set<String> get unaggregatedColumns =>
      isAggregate ? {} : super.unaggregatedColumns;
  static const maxOutputUnits = 16 * 1024 * 1024;
  static void _checkOutput(int length) {
    if (length > maxOutputUnits) {
      throw const SqlException('Function output limit exceeded');
    }
  }

  static const windowNames = {
    'row_number',
    'rank',
    'dense_rank',
    'percent_rank',
    'cume_dist',
    'ntile',
    'lag',
    'lead',
    'first_value',
    'last_value',
    'nth_value'
  };
  static const _arities = <String, (int, int)>{
    'changes': (0, 0),
    'total_changes': (0, 0),
    'last_insert_rowid': (0, 0),
    'likely': (1, 1),
    'unlikely': (1, 1),
    'likelihood': (2, 2),
    'printf': (0, 1000),
    'format': (0, 1000),
    'like': (2, 3),
    'glob': (2, 2),
    'match': (2, 2),
    'row_number': (0, 0),
    'rank': (0, 0),
    'dense_rank': (0, 0),
    'percent_rank': (0, 0),
    'cume_dist': (0, 0),
    'ntile': (1, 1),
    'lag': (1, 3),
    'lead': (1, 3),
    'first_value': (1, 1),
    'last_value': (1, 1),
    'nth_value': (2, 2),
    'abs': (1, 1),
    'length': (1, 1),
    'lower': (1, 1),
    'upper': (1, 1),
    'typeof': (1, 1),
    'coalesce': (2, 1000),
    'ifnull': (2, 2),
    'nullif': (2, 2),
    'iif': (2, 1000),
    'if': (2, 1000),
    ...extraFunctionArities,
    ...dateFunctionArities,
    'hex': (1, 1),
    'quote': (1, 1),
    'unistr_quote': (1, 1),
    'unicode': (1, 1),
    'char': (0, 1000),
    'substr': (2, 3),
    'substring': (2, 3),
    'replace': (3, 3),
    'trim': (1, 2),
    'ltrim': (1, 2),
    'rtrim': (1, 2),
    'zeroblob': (1, 1),
    'count': (0, 1),
    'sum': (1, 1),
    'total': (1, 1),
    'avg': (1, 1),
    'min': (1, 1000),
    'max': (1, 1000),
    'group_concat': (1, 2),
    'string_agg': (2, 2),
    'median': (1, 1),
    'percentile': (2, 2),
    'percentile_cont': (2, 2),
    'percentile_disc': (2, 2),
    ...jsonFunctionArities,
  };
  static Map<String, (int, int)> get builtinArities => _arities;
  @override
  void validate(Set<String> columns) {
    if (!deferValidation) _resolveSignature();
    if (isAggregate &&
        !windowFunction &&
        arguments.any((arg) => arg.containsAggregate)) {
      throw const SqlException('Nested aggregate');
    }
    if (order.isNotEmpty && (!isAggregate || windowFunction)) {
      throw const SqlException(
          'Aggregate ORDER BY requires a non-window aggregate');
    }
    for (final term in order) {
      term.expression.validate(columns);
      if (term.expression.containsAggregate || term.expression.containsWindow) {
        throw const SqlException('Aggregate/window in aggregate ORDER BY');
      }
    }
    filter?.validate(columns);
    if (filter != null &&
        (!isAggregate ||
            !windowFunction && filter!.containsAggregate ||
            filter!.containsWindow)) {
      throw const SqlException('Invalid aggregate FILTER');
    }
    for (final arg in arguments) {
      arg.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    _resolveSignature();
    if (registered == null && windowNames.contains(key)) {
      throw const SqlException('Window function requires OVER');
    }
    if (isAggregate) {
      return context.aggregateValues.containsKey(this)
          ? context.aggregateValues[this]
          : _aggregate(context);
    }
    if (registered != null) {
      return registered!
          .invoke(arguments.map((arg) => arg.evaluate(context)).toList());
    }
    if (key == 'changes') {
      return SqlFunctionRegistry.current?.connectionState.changes ??
          BigInt.zero;
    }
    if (key == 'total_changes') {
      return SqlFunctionRegistry.current?.connectionState.totalChanges ??
          BigInt.zero;
    }
    if (key == 'last_insert_rowid') {
      return SqlFunctionRegistry.current?.connectionState.lastInsertRowid ??
          BigInt.zero;
    }
    if (key == 'coalesce' || key == 'ifnull') {
      for (final arg in arguments) {
        final value = arg.evaluate(context);
        if (value != null) return value;
      }
      return null;
    }
    if (key == 'iif' || key == 'if') {
      for (var i = 0; i + 1 < arguments.length; i += 2) {
        if (truth(arguments[i].evaluate(context), context.encoding) == true) {
          return arguments[i + 1].evaluate(context);
        }
      }
      return arguments.length.isOdd ? arguments.last.evaluate(context) : null;
    }
    if (['likely', 'unlikely', 'likelihood'].contains(key)) {
      return arguments.first.evaluate(context);
    }
    final collation = arguments
        .map((arg) => arg.collation(context))
        .whereType<String>()
        .firstOrNull;
    final args = arguments.map((arg) => arg.evaluate(context)).toList();
    if (isJsonFunction(key)) {
      return evaluateJsonFunction(key, args, context.encoding);
    }
    for (var index = 0; index < args.length; index++) {
      final value = args[index];
      if (value is JsonText) args[index] = value.text;
    }
    if (key == 'printf' || key == 'format') {
      return sqlitePrintf(args, context.encoding);
    }
    if (key == 'like' || key == 'glob') {
      return PatternExpr(Literal(args[1]), Literal(args[0]),
              escape: args.length == 3 ? Literal(args[2]) : null,
              glob: key == 'glob')
          .evaluate(context);
    }
    if (key == 'match') {
      throw const SqlException(
          'Unable to use function MATCH in the requested context');
    }
    if (dateFunctionArities.containsKey(key)) {
      final timeArgs = key == 'strftime' ? args.skip(1).toList() : args;
      bool rawNow(Object? value) =>
          value is String &&
          ['now', 'subsec', 'subsecond'].contains(asciiLower(value));
      if (context.schemaExpression &&
          (timeArgs.isEmpty ||
              (key == 'timediff'
                  ? timeArgs.any(rawNow)
                  : rawNow(timeArgs.first)) ||
              timeArgs.any((value) =>
                  value is String &&
                  ['localtime', 'utc'].contains(asciiLower(value))))) {
        throw const SqlException(
            'Non-deterministic date/time in schema expression');
      }
      return dateFunction(key, args, context.encoding);
    }
    if (extraFunctionArities.containsKey(key)) {
      return extraFunction(key, args, context.encoding);
    }
    if (key == 'typeof') {
      return args[0] == null
          ? 'null'
          : args[0] is BigInt
              ? 'integer'
              : args[0] is double
                  ? 'real'
                  : args[0] is String
                      ? 'text'
                      : 'blob';
    }
    if (key == 'nullif') {
      return compareValues(args[0], args[1], context.encoding, collation) == 0
          ? null
          : args[0];
    }
    if (key == 'hex') {
      final value = args[0];
      final bytes = value == null
          ? <int>[]
          : value is Uint8List
              ? value
              : encodeSqlText(stringify(value), context.encoding);
      _checkOutput(bytes.length * 2);
      return bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
    }
    if (key == 'quote' || key == 'unistr_quote') {
      final value = args[0];
      if (value == null) return 'NULL';
      if (value is Uint8List) {
        _checkOutput(value.length * 2 + 3);
        return "X'${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}'";
      }
      if (value is String) {
        final text = value.split('\u0000').first;
        if (key == 'unistr_quote' &&
            text.codeUnits.any((unit) => unit >= 1 && unit <= 31)) {
          final output = StringBuffer("unistr('");
          for (final unit in text.codeUnits) {
            if (unit >= 1 && unit <= 31) {
              output.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
            } else {
              output.writeCharCode(unit);
              if (unit == 39 || unit == 92) output.writeCharCode(unit);
            }
            _checkOutput(output.length + 2);
          }
          return "$output')";
        }
        _checkOutput(text.length + "'".allMatches(text).length + 2);
        return "'${text.replaceAll("'", "''")}'";
      }
      if (value is double && value.isInfinite) {
        return value.isNegative ? '-9.0e+999' : '9.0e+999';
      }
      if (value is double) {
        final candidate = sqlRealText(value);
        return double.parse(candidate) == value
            ? candidate
            : sqlRealText(value, 17);
      }
      return stringify(value);
    }
    if (key == 'char') {
      return String.fromCharCodes(args.map((v) {
        final n = scalarInt64(v, context.encoding);
        return n < BigInt.zero ||
                n > BigInt.from(0x10ffff) ||
                n >= BigInt.from(0xd800) && n <= BigInt.from(0xdfff)
            ? 0xfffd
            : n.toInt();
      }));
    }
    if (args.any((arg) => arg == null)) return null;
    final value = args.first!;
    String text(Object v) => stringify(v, context.encoding);
    BigInt integer(Object v) => scalarInt64(v, context.encoding);
    if (key == 'abs') {
      if (value is BigInt) {
        if (value == -(BigInt.one << 63)) {
          throw const SqlException('integer overflow');
        }
        return value.abs();
      }
      final n = numeric(value, prefix: true, encoding: context.encoding);
      return n is BigInt ? n.toDouble().abs() : (n as double? ?? 0.0).abs();
    }
    if (key == 'length') {
      return BigInt.from(value is Uint8List
          ? value.length
          : text(value).split('\u0000').first.runes.length);
    }
    if (key == 'lower' || key == 'upper') {
      return String.fromCharCodes(
          text(value).codeUnits.map((c) => key == 'lower' && c >= 65 && c <= 90
              ? c + 32
              : key == 'upper' && c >= 97 && c <= 122
                  ? c - 32
                  : c));
    }
    if (key == 'unicode') {
      final s = text(value);
      return s.isEmpty || s.codeUnitAt(0) == 0
          ? null
          : BigInt.from(s.runes.first);
    }
    if (key == 'zeroblob') {
      final n = integer(value);
      if (n > BigInt.from(16 * 1024 * 1024)) {
        throw const SqlException('zeroblob limit exceeded');
      }
      return Uint8List(n < BigInt.zero ? 0 : n.toInt());
    }
    if (key == 'replace') {
      final input = text(value);
      final pattern = text(args[1]!);
      final replacement = text(args[2]!);
      if (pattern.isEmpty) return input;
      if (replacement.length > pattern.length) {
        var matches = 0;
        var offset = 0;
        while (true) {
          final found = input.indexOf(pattern, offset);
          if (found < 0) break;
          matches++;
          offset = found + pattern.length;
        }
        _checkOutput(
            input.length + matches * (replacement.length - pattern.length));
      }
      return input.replaceAll(pattern, replacement);
    }
    if (['trim', 'ltrim', 'rtrim'].contains(key)) {
      final units = text(value).runes.toList();
      final chars = (args.length == 1 ? ' ' : text(args[1]!)).runes.toSet();
      var start = 0;
      var end = units.length;
      if (key != 'rtrim') {
        while (start < end && chars.contains(units[start])) {
          start++;
        }
      }
      if (key != 'ltrim') {
        while (end > start && chars.contains(units[end - 1])) {
          end--;
        }
      }
      return String.fromCharCodes(units.sublist(start, end));
    }
    if (key == 'substr' || key == 'substring') {
      final units =
          value is Uint8List ? value.toList() : text(value).runes.toList();
      var start = integer(args[1]!);
      var length =
          args.length == 3 ? integer(args[2]!) : BigInt.from(0x7fffffff);
      if (start < BigInt.zero) {
        start += BigInt.from(units.length);
        if (start < BigInt.zero) {
          length += start;
          start = BigInt.zero;
        }
      } else if (start > BigInt.zero) {
        start -= BigInt.one;
      } else if (length > BigInt.zero) {
        length -= BigInt.one;
      }
      if (length < BigInt.zero) {
        length = -length;
        if (length > start) length = start;
        start -= length;
      }
      start = start.clamp(BigInt.zero, BigInt.from(units.length));
      length = length.clamp(BigInt.zero, BigInt.from(units.length) - start);
      final selected = units.sublist(start.toInt(), (start + length).toInt());
      return value is Uint8List
          ? Uint8List.fromList(selected)
          : String.fromCharCodes(selected);
    }
    if (key == 'min' || key == 'max') {
      var result = value;
      for (final item in args.skip(1)) {
        final cmp = compareValues(item, result, context.encoding, collation);
        if (key == 'min' ? cmp <= 0 : cmp > 0) result = item!;
      }
      return result;
    }
    throw SqlException('Unsupported function $name');
  }

  Object? _aggregate(EvalContext context) {
    final group = context.group;
    if (group == null) {
      throw const SqlException('Aggregate used outside aggregate query');
    }
    final accumulator = PreparedSqlAggregate(this, context);
    for (final row in group) {
      accumulator.step(context.forRow(row));
    }
    return accumulator.finish();
  }

  Object? _finishAggregate(
      EvalContext context, List<(List<Object?>, List<Object?>, int)> prepared) {
    if (order.isNotEmpty) {
      prepared.sort((a, b) {
        for (var i = 0; i < order.length; i++) {
          final comparison = order[i].compare(a.$2[i], b.$2[i], context);
          if (comparison != 0) return comparison;
        }
        return a.$3.compareTo(b.$3);
      });
    }
    if (isJsonAggregate(key)) {
      return finishJsonAggregate(
          key, [for (final entry in prepared) entry.$1], context.encoding);
    }
    if (registered != null) {
      try {
        final state = registered!.aggregate!();
        for (final entry in prepared) {
          state.step(List.unmodifiable(entry.$1.map(sqlValue)));
        }
        return sqlValue(state.finish());
      } on SqlException {
        rethrow;
      } catch (_) {
        throw SqlException('User aggregate $name failed');
      }
    }
    if (percentileFunctionNames.contains(key)) {
      return percentileAggregate(key, prepared.map((entry) => entry.$1));
    }
    final argumentsByRow = [
      for (final entry in prepared)
        if (entry.$1.first != null) entry.$1
    ];
    final values = [for (final args in argumentsByRow) args.first];
    if (key == 'count') return BigInt.from(values.length);
    if (key == 'min' || key == 'max') {
      if (values.isEmpty) return null;
      var result = values.first;
      for (final value in values.skip(1)) {
        final cmp = compareValues(value, result, context.encoding,
            arguments.first.collation(context));
        if (key == 'min' ? cmp < 0 : cmp > 0) result = value;
      }
      return result;
    }
    if (key == 'group_concat' || key == 'string_agg') {
      if (values.isEmpty) return null;
      final result = StringBuffer();
      for (var i = 0; i < values.length; i++) {
        if (i > 0) {
          final separator = arguments.length == 1 ? ',' : argumentsByRow[i][1];
          if (separator != null) {
            _checkOutput(
                result.length + stringify(separator, context.encoding).length);
            result.write(stringify(separator, context.encoding));
          }
        }
        final piece = stringify(values[i]!, context.encoding);
        _checkOutput(result.length + piece.length);
        result.write(piece);
      }
      return result.toString();
    }
    if (values.isEmpty) return key == 'total' ? 0.0 : null;
    var integer = BigInt.zero;
    var real = 0.0;
    var correction = 0.0;
    void add(double value) {
      final total = real + value;
      if (!real.isFinite || !value.isFinite || !total.isFinite) {
        real = total;
        correction = 0;
        return;
      }
      correction += real.abs() > value.abs()
          ? (real - total) + value
          : (value - total) + real;
      real = total;
    }

    void addInteger(BigInt value) {
      final high = (value ~/ BigInt.from(16384)) * BigInt.from(16384);
      add(high.toDouble());
      add((value - high).toDouble());
    }

    var floating = key != 'sum';
    for (final value in values) {
      var n = numeric(value, prefix: true, encoding: context.encoding) ??
          BigInt.zero;
      if (value is String && value.contains('\u0000')) {
        n = numeric(value) ?? n;
      }
      if (value is Uint8List || value is String && numeric(value) == null) {
        n = n is BigInt ? n.toDouble() : n;
      }
      if (n is BigInt && !floating) {
        integer += n;
        if (integer < -(BigInt.one << 63) || integer >= BigInt.one << 63) {
          throw const SqlException('integer overflow');
        }
      } else {
        if (!floating) {
          addInteger(integer);
          floating = true;
        }
        if (n is BigInt) {
          addInteger(n);
        } else {
          add(n as double);
        }
      }
    }
    if (floating && real.isFinite) real += correction;
    if (key == 'avg') return real.isNaN ? null : real / values.length;
    if (floating) return real.isNaN ? null : real;
    return integer;
  }
}

/// One accumulator per prepared aggregate. The executor advances all
/// accumulators for one input row before requesting the next source row.
/// Ordered aggregates retain arguments until their local sort is complete.
final class PreparedSqlAggregate {
  PreparedSqlAggregate(this.function, this.context) {
    if (function.registered != null && function.order.isEmpty) {
      try {
        _state = function.registered!.aggregate!();
      } on SqlException {
        rethrow;
      } catch (_) {
        throw SqlException('User aggregate ${function.name} failed');
      }
    }
  }
  final FunctionExpr function;
  final EvalContext context;
  final _prepared = <(List<Object?>, List<Object?>, int)>[];
  SqlAggregate? _state;
  RowValues? representative;
  Object? _extreme;
  bool _copyBare = true;

  void step(EvalContext row) {
    final fn = function;
    if (fn.filter != null &&
        truth(fn.filter!.evaluate(row), row.encoding) != true) {
      return;
    }
    final reuse = fn.arguments.length == 1 &&
        fn.order.length == 1 &&
        sameExpression(fn.arguments.single, fn.order.single.expression);
    final keys = reuse
        ? <Object?>[]
        : fn.order.map((term) => term.expression.evaluate(row)).toList();
    final args = fn.star || fn.arguments.isEmpty
        ? (fn.registered == null ? <Object?>[BigInt.one] : <Object?>[])
        : fn.arguments.map((argument) => argument.evaluate(row)).toList();
    if (reuse) keys.add(args.single);
    if (fn.distinct) {
      final existing = _prepared.indexWhere((entry) =>
          compareValues(entry.$1.single, args.single, context.encoding,
              fn.arguments.single.collation(context)) ==
          0);
      if (existing >= 0) {
        if (reuse) _prepared[existing] = (args, keys, _prepared[existing].$3);
        if (fn.registered == null &&
            ['min', 'max'].contains(fn.key) &&
            _copyBare) {
          representative = row.row;
        }
        return;
      }
    }
    _prepared.add((args, keys, _prepared.length));
    if (fn.registered == null && ['min', 'max'].contains(fn.key)) {
      final value = args.single;
      if (value == null) {
        _copyBare = _extreme == null;
      } else {
        final comparison = _extreme == null
            ? 0
            : compareValues(value, _extreme, context.encoding,
                fn.arguments.single.collation(context));
        _copyBare = _extreme == null ||
            (fn.key == 'min' ? comparison < 0 : comparison > 0);
        if (_copyBare) _extreme = value;
      }
      if (_copyBare) representative = row.row;
    }
    if (_state != null) {
      try {
        _state!.step(List.unmodifiable(args.map(sqlValue)));
      } on SqlException {
        rethrow;
      } catch (_) {
        throw SqlException('User aggregate ${fn.name} failed');
      }
    }
  }

  Object? finish() {
    if (_state != null) {
      try {
        return sqlValue(_state!.finish());
      } on SqlException {
        rethrow;
      } catch (_) {
        throw SqlException('User aggregate ${function.name} failed');
      }
    }
    return function._finishAggregate(context, _prepared);
  }
}

extension _BoundedBigInt on BigInt {
  BigInt clamp(BigInt low, BigInt high) => this < low
      ? low
      : this > high
          ? high
          : this;
}

Iterable<FunctionExpr> aggregateFunctions(Expr expr) sync* {
  if (expr is FunctionExpr && expr.isAggregate) {
    yield expr;
    return;
  }
  for (final child in expr.children) {
    yield* aggregateFunctions(child);
  }
}
