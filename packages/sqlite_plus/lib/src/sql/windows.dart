import 'parser.dart';
import 'functions.dart';
import 'values.dart';
import 'tokenizer.dart';

final class WindowBound {
  WindowBound(this.kind, [this.offset]);
  final String kind;
  final Expr? offset;
}

final class _WindowRow {
  _WindowRow(this.row, this.partition, this.order, this.ordinal);
  final RowValues row;
  final List<Object?> partition, order;
  final int ordinal;
}

final class WindowExpr extends Expr {
  WindowExpr(this.function, this.partition, this.order, this.mode, this.start,
      this.end,
      [this.exclusion = 'NO OTHERS']);
  final FunctionExpr function;
  final List<Expr> partition;
  final List<OrderTerm> order;
  String mode;
  WindowBound start, end;
  String exclusion;
  String? baseName;
  bool directName = false, explicitFrame = false, _resolved = false;
  void resolve(Map<String, WindowExpr> definitions, Set<String> visiting) {
    if (_resolved) return;
    final name = baseName;
    if (name != null) {
      final base = definitions[name];
      if (base == null || !visiting.add(name)) {
        throw const SqlException('Unknown or cyclic window');
      }
      base.resolve(definitions, visiting);
      visiting.remove(name);
      if (directName) {
        partition.addAll(base.partition);
        order.addAll(base.order);
        mode = base.mode;
        start = base.start;
        end = base.end;
        exclusion = base.exclusion;
        explicitFrame = base.explicitFrame;
      } else {
        if (partition.isNotEmpty ||
            order.isNotEmpty && base.order.isNotEmpty ||
            base.explicitFrame) {
          throw const SqlException('Cannot override base window');
        }
        partition.addAll(base.partition);
        if (order.isEmpty) order.addAll(base.order);
        if (!explicitFrame) {
          end = WindowBound(
              order.isEmpty ? 'UNBOUNDED FOLLOWING' : 'CURRENT ROW');
        }
      }
    }
    _resolved = true;
  }

  @override
  Iterable<Expr> get children => [
        ...function.arguments,
        if (function.filter != null) function.filter!,
        ...partition,
        ...order.map((o) => o.expression),
        if (start.offset != null) start.offset!,
        if (end.offset != null) end.offset!
      ];
  @override
  bool get containsWindow => true;
  @override
  Set<String> get unaggregatedColumns =>
      children.expand((c) => c.unaggregatedColumns).toSet();
  @override
  void validate(Set<String> columns) {
    if (function.distinct) {
      throw const SqlException('DISTINCT in window function');
    }
    if (children.any((c) => c.containsWindow || c.containsAggregate)) {
      throw const SqlException('Nested window or grouped window unsupported');
    }
    function.validate(columns);
    for (final expr in [...partition, ...order.map((o) => o.expression)]) {
      expr.validate(columns);
    }
    if (mode == 'RANGE' &&
        (start.offset != null || end.offset != null) &&
        order.length != 1) {
      throw const SqlException('Offset RANGE requires one ORDER BY expression');
    }
    start.offset?.validate({});
    end.offset?.validate({});
    if (!function.isAggregate &&
        !FunctionExpr.windowNames.contains(function.key)) {
      throw const SqlException('Function cannot be a window');
    }
  }

  EvalContext _context(EvalContext source, RowValues row) =>
      EvalContext(row, source.affinities, source.parameters, source.encoding)
        ..collations = source.collations
        ..subquery = source.subquery;
  @override
  Object? evaluate(EvalContext context) {
    final rows = context.windowRows;
    final current = context.windowRow;
    if (rows == null || current == null) {
      throw const SqlException('Window function outside SELECT projection');
    }
    if (rows.length > 10000) {
      throw const SqlException('Window materialization limit exceeded');
    }
    final positions = context.windowCache.putIfAbsent(this, () {
      final sorted = <_WindowRow>[];
      for (var i = 0; i < rows.length; i++) {
        final ctx = _context(context, rows[i]);
        sorted.add(_WindowRow(
            rows[i],
            partition.map((e) => e.evaluate(ctx)).toList(),
            order.map((o) => o.expression.evaluate(ctx)).toList(),
            i));
      }
      int compare(List<Object?> a, List<Object?> b, List<Expr> exprs) {
        for (var i = 0; i < a.length; i++) {
          final c = compareValues(
              a[i], b[i], context.encoding, exprs[i].collation(context));
          if (c != 0) return c;
        }
        return 0;
      }

      sorted.sort((a, b) {
        final p = compare(a.partition, b.partition, partition);
        if (p != 0) return p;
        for (var i = 0; i < order.length; i++) {
          final c = order[i].compare(a.order[i], b.order[i], context);
          if (c != 0) return c;
        }
        return a.ordinal.compareTo(b.ordinal);
      });
      final result = <RowValues, (List<_WindowRow>, int)>{};
      var first = 0;
      while (first < sorted.length) {
        var last = first + 1;
        while (last < sorted.length &&
            compare(sorted[first].partition, sorted[last].partition,
                    partition) ==
                0) {
          last++;
        }
        final group = sorted.sublist(first, last);
        for (var i = 0; i < group.length; i++) {
          result[group[i].row] = (group, i);
        }
        first = last;
      }
      return result;
    }) as Map<RowValues, (List<_WindowRow>, int)>;
    final position = positions[current]!;
    final group = position.$1;
    final index = position.$2;
    bool peer(int a, int b) {
      for (var i = 0; i < order.length; i++) {
        if (compareValues(group[a].order[i], group[b].order[i],
                context.encoding, order[i].expression.collation(context)) !=
            0) {
          return false;
        }
      }
      return true;
    }

    var peerStart = index;
    while (peerStart > 0 && peer(peerStart - 1, index)) {
      peerStart--;
    }
    var peerEnd = index;
    while (peerEnd + 1 < group.length && peer(peerEnd + 1, index)) {
      peerEnd++;
    }
    final key = function.key;
    Object? arg(int argument, int row) => function.arguments[argument]
        .evaluate(_context(context, group[row].row));
    int integer(Object? value, {bool positive = false}) {
      value = numeric(value);
      if (value is double &&
          value.isFinite &&
          value == value.truncateToDouble()) {
        value = BigInt.from(value);
      }
      if (value is! BigInt || value < BigInt.from(positive ? 1 : 0)) {
        throw const SqlException('Window offset must be a nonnegative integer');
      }
      return value > BigInt.from(0x7fffffff) ? 0x7fffffff : value.toInt();
    }

    if (key == 'row_number') return BigInt.from(index + 1);
    if (key == 'rank') return BigInt.from(peerStart + 1);
    if (key == 'dense_rank') {
      var rank = 1;
      for (var i = 1; i <= index; i++) {
        if (!peer(i - 1, i)) rank++;
      }
      return BigInt.from(rank);
    }
    if (key == 'percent_rank') {
      return group.length == 1 ? 0.0 : peerStart / (group.length - 1);
    }
    if (key == 'cume_dist') return (peerEnd + 1) / group.length;
    if (key == 'ntile') {
      final value = numeric(arg(0, 0));
      final buckets = integer(
          value is double && value.isFinite ? BigInt.from(value) : value,
          positive: true);
      final small = group.length ~/ buckets;
      final large = group.length % buckets;
      final split = (small + 1) * large;
      return BigInt.from(index < split
          ? index ~/ (small + 1) + 1
          : large + (index - split) ~/ small + 1);
    }
    if (key == 'lag' || key == 'lead') {
      var value =
          function.arguments.length > 1 ? numeric(arg(1, index)) : BigInt.one;
      if (value is double &&
          value.isFinite &&
          value == value.truncateToDouble()) {
        value = BigInt.from(value);
      }
      final fallback = function.arguments.length > 2 ? arg(2, index) : null;
      if (value is! BigInt || value.abs() > BigInt.from(0x7fffffff)) {
        return fallback;
      }
      final offset = value.toInt();
      final target = index + (key == 'lag' ? -offset : offset);
      return target < 0 || target >= group.length ? fallback : arg(0, target);
    }
    int boundary(WindowBound bound, bool ending) {
      switch (bound.kind) {
        case 'UNBOUNDED PRECEDING':
          return 0;
        case 'UNBOUNDED FOLLOWING':
          return group.length - 1;
        case 'CURRENT ROW':
          return mode != 'ROWS' ? (ending ? peerEnd : peerStart) : index;
        default:
          final raw = bound.offset!.evaluate(_context(context, {}));
          if (mode == 'RANGE') {
            final offset = numeric(raw);
            if (offset is! BigInt && offset is! double ||
                offset is BigInt && offset < BigInt.zero ||
                offset is double && (offset.isNaN || offset < 0)) {
              throw const SqlException('RANGE offset must be nonnegative');
            }
            final value = group[index].order.single;
            if (value is! BigInt && value is! double) {
              return ending ? peerEnd : peerStart;
            }
            final subtract =
                (bound.kind == 'PRECEDING') != order.single.descending;
            final target = BinaryExpr(
                    subtract ? '-' : '+', Literal(value), Literal(offset))
                .evaluate(context);
            if (ending) {
              for (var i = group.length - 1; i >= 0; i--) {
                final c = order.single
                    .compare(group[i].order.single, target, context);
                if (c <= 0) return i;
              }
              return -1;
            }
            for (var i = 0; i < group.length; i++) {
              final c =
                  order.single.compare(group[i].order.single, target, context);
              if (c >= 0) return i;
            }
            return group.length;
          }
          final offset = integer(raw);
          if (mode == 'GROUPS') {
            final starts = <int>[0];
            for (var i = 1; i < group.length; i++) {
              if (!peer(i - 1, i)) starts.add(i);
            }
            final currentGroup =
                starts.lastIndexWhere((start) => start <= index);
            final target =
                currentGroup + (bound.kind == 'PRECEDING' ? -offset : offset);
            if (target < 0) return ending ? -1 : 0;
            if (target >= starts.length) {
              return ending ? group.length - 1 : group.length;
            }
            return ending
                ? (target + 1 < starts.length
                    ? starts[target + 1] - 1
                    : group.length - 1)
                : starts[target];
          }
          return index + (bound.kind == 'PRECEDING' ? -offset : offset);
      }
    }

    var first = boundary(start, false), last = boundary(end, true);
    if (first < 0) first = 0;
    if (last >= group.length) last = group.length - 1;
    final frame = first > last || first >= group.length || last < 0
        ? <RowValues>[]
        : [
            for (var i = first; i <= last; i++)
              if (exclusion == 'NO OTHERS' ||
                  exclusion == 'CURRENT ROW' && i != index ||
                  exclusion == 'GROUP' && !peer(i, index) ||
                  exclusion == 'TIES' && (i == index || !peer(i, index)))
                group[i].row
          ];
    if (['first_value', 'last_value', 'nth_value'].contains(key)) {
      final target = key == 'first_value'
          ? 0
          : key == 'last_value'
              ? frame.length - 1
              : integer(arg(1, index), positive: true) - 1;
      return target < 0 || target >= frame.length
          ? null
          : function.arguments.first.evaluate(_context(context, frame[target]));
    }
    return function.evaluate(_context(context, current)..group = frame);
  }
}
