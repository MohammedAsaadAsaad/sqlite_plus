import 'dart:typed_data';

import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

final class FunctionExpr extends Expr {
  FunctionExpr(this.name, this.arguments,
      {this.distinct = false, this.star = false}) {
    final range = _arities[key];
    if (range == null) throw SqlException('No such function: $name');
    if (arguments.length < range.$1 ||
        arguments.length > range.$2 ||
        star && key != 'count' ||
        distinct && !isAggregate ||
        distinct && arguments.length != 1) {
      throw SqlException('Invalid arguments to $name');
    }
    if (isAggregate && arguments.any((arg) => arg.containsAggregate)) {
      throw const SqlException('Nested aggregate');
    }
  }
  final String name;
  final List<Expr> arguments;
  final bool distinct;
  final bool star;
  String get key => asciiLower(name);
  bool get isAggregate =>
      ['count', 'sum', 'total', 'avg', 'group_concat'].contains(key) ||
      ['min', 'max'].contains(key) && arguments.length == 1;
  @override
  Iterable<Expr> get children => arguments;
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

  static const _arities = <String, (int, int)>{
    'abs': (1, 1),
    'length': (1, 1),
    'lower': (1, 1),
    'upper': (1, 1),
    'typeof': (1, 1),
    'coalesce': (2, 127),
    'ifnull': (2, 2),
    'nullif': (2, 2),
    'iif': (3, 3),
    'hex': (1, 1),
    'quote': (1, 1),
    'unicode': (1, 1),
    'char': (0, 127),
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
    'min': (1, 127),
    'max': (1, 127),
    'group_concat': (1, 2),
  };
  @override
  void validate(Set<String> columns) {
    for (final arg in arguments) {
      arg.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    if (isAggregate) {
      return context.aggregateValues.containsKey(this)
          ? context.aggregateValues[this]
          : _aggregate(context);
    }
    if (key == 'coalesce' || key == 'ifnull') {
      for (final arg in arguments) {
        final value = arg.evaluate(context);
        if (value != null) return value;
      }
      return null;
    }
    if (key == 'iif') {
      return arguments[
              truth(arguments[0].evaluate(context), context.encoding) == true
                  ? 1
                  : 2]
          .evaluate(context);
    }
    final args = arguments.map((arg) => arg.evaluate(context)).toList();
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
      return compareValues(args[0], args[1], context.encoding) == 0
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
    if (key == 'quote') {
      final value = args[0];
      if (value == null) return 'NULL';
      if (value is Uint8List) {
        _checkOutput(value.length * 2 + 3);
        return "X'${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}'";
      }
      if (value is String) {
        final text = value.split('\u0000').first;
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
        final n = toSqlInteger(
            numeric(v, prefix: true, encoding: context.encoding) ??
                BigInt.zero);
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
    BigInt integer(Object v) => toSqlInteger(
        numeric(v, prefix: true, encoding: context.encoding) ?? BigInt.zero);
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
        final cmp = compareValues(item, result, context.encoding);
        if (key == 'min' ? cmp < 0 : cmp > 0) result = item!;
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
    final values = <Object?>[];
    final contexts = <EvalContext>[];
    for (final row in group) {
      final ctx = EvalContext(
          row, context.affinities, context.parameters, context.encoding);
      final value = star || arguments.isEmpty
          ? BigInt.one
          : arguments.first.evaluate(ctx);
      if (value == null) continue;
      if (distinct &&
          values.any((v) => compareValues(v, value, context.encoding) == 0)) {
        continue;
      }
      values.add(value);
      contexts.add(ctx);
    }
    if (key == 'count') return BigInt.from(values.length);
    if (key == 'min' || key == 'max') {
      if (values.isEmpty) return null;
      var result = values.first;
      for (final value in values.skip(1)) {
        final cmp = compareValues(value, result, context.encoding);
        if (key == 'min' ? cmp < 0 : cmp > 0) result = value;
      }
      return result;
    }
    if (key == 'group_concat') {
      if (values.isEmpty) return null;
      final result = StringBuffer();
      for (var i = 0; i < values.length; i++) {
        if (i > 0) {
          final separator =
              arguments.length == 1 ? ',' : arguments[1].evaluate(contexts[i]);
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
