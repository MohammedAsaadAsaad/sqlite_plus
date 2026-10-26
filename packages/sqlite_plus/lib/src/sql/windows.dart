import 'parser.dart';
import 'expressions.dart';
import 'functions.dart';
import 'values.dart';
import 'tokenizer.dart';
import 'percentile_functions.dart';
import 'index_definition.dart' show sameExpression;

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

/// The input side of a window coroutine. Values are captured when a row enters
/// that coroutine, once per function, before FILTER decides whether to step it.
final class _WindowInput {
  _WindowInput(this.arguments, this.accepted);
  final List<Object?> arguments;
  final bool accepted;
}

final class _WindowState {
  _WindowState(this.expression, this.context, this.rows, this.streaming);
  final WindowExpr expression;
  final EvalContext context;
  final List<RowValues> rows;
  final bool streaming;
  final List<_WindowRow> sorted = [];
  final Map<RowValues, (List<_WindowRow>, int)> positions = {};
  final Map<RowValues, _WindowInput> inputs = {};
  final Map<WindowBound, Object?> offsets = {};
  bool validatedOffsets = false;
  late _WindowStage stage;

  void validateOffsets() {
    if (validatedOffsets) return;
    validatedOffsets = true;
    final window = expression;
    if ([
      'row_number',
      'rank',
      'dense_rank',
      'percent_rank',
      'cume_dist',
      'lag',
      'lead',
      'ntile'
    ].contains(window.function.key)) {
      return;
    }
    bool constant(Expr expression) =>
        expression is! FunctionExpr &&
        expression is! SubqueryExpr &&
        expression is! InSelectExpr &&
        (expression is! ColumnExpr || expression is BoolNameExpr) &&
        expression.children.every(constant);
    for (final bound in [window.start, window.end]) {
      if (bound.offset == null) continue;
      var value = constant(bound.offset!)
          ? numeric(bound.offset!.evaluate(context.forRow({})))
          : null;
      if (window.mode != 'RANGE' &&
          value is double &&
          value.isFinite &&
          value == value.truncateToDouble()) {
        value = BigInt.from(value);
      }
      if (value is! BigInt && (window.mode != 'RANGE' || value is! double) ||
          value is BigInt && value < BigInt.zero ||
          value is double && (value.isNaN || value < 0) ||
          window.mode != 'RANGE' &&
              value is BigInt &&
              value > (BigInt.one << 63) - BigInt.one) {
        throw const SqlException('Window frame offset must be nonnegative');
      }
      offsets[bound] = value;
    }
  }

  void capture(RowValues row) {
    if (inputs.containsKey(row)) return;
    final ctx = context.forRow(row);
    final args = expression.function.arguments
        .map((argument) => argument.evaluate(ctx))
        .toList();
    final filter = expression.function.filter;
    final accepted =
        filter == null || truth(filter.evaluate(ctx), ctx.encoding) == true;
    inputs[row] = _WindowInput(args, accepted);
  }

  void keys() {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final ctx = context.forRow(row);
      sorted.add(_WindowRow(
          row,
          expression.partition.map((e) => e.evaluate(ctx)).toList(),
          expression.order.map((o) => o.expression.evaluate(ctx)).toList(),
          i));
    }
    sorted.sort((a, b) {
      final comparison = comparePartition(a.partition, b.partition);
      if (comparison != 0) return comparison;
      for (var i = 0; i < expression.order.length; i++) {
        final c = expression.order[i].compare(a.order[i], b.order[i], context);
        if (c != 0) return c;
      }
      return a.ordinal.compareTo(b.ordinal);
    });
    var first = 0;
    while (first < sorted.length) {
      var last = first + 1;
      while (last < sorted.length &&
          comparePartition(sorted[first].partition, sorted[last].partition) ==
              0) {
        last++;
      }
      final group = sorted.sublist(first, last);
      for (var i = 0; i < group.length; i++) {
        positions[group[i].row] = (group, i);
      }
      first = last;
    }
  }

  int comparePartition(List<Object?> a, List<Object?> b) {
    for (var i = 0; i < a.length; i++) {
      final comparison = compareValues(a[i], b[i], context.encoding,
          expression.partition[i].collation(context));
      if (comparison != 0) return comparison;
    }
    return 0;
  }
}

Map<SqlValueBinding, Object?> _captureWindowProjection(
    RowValues row, Set<String> names) {
  final values = <SqlValueBinding, Object?>{};
  for (final name in names) {
    final value = row[name];
    if (value is SqlValueBinding && !values.containsKey(value)) {
      values[value] = resolveSqlValue(value);
    }
  }
  return values;
}

void _freezeWindowProjection(
    RowValues row, Map<SqlValueBinding, Object?> values) {
  if (values.isNotEmpty) {
    row.updateAll((key, value) =>
        value is SqlValueBinding && values.containsKey(value)
            ? values[value]
            : value);
  }
}

final class _WindowStage {
  _WindowStage(this.states);
  final List<_WindowState> states;
  _WindowStage? upstream;
  Set<String> projectedColumns = {};
  var fetched = 0;
  List<_WindowRow> get sorted => states.first.sorted;

  void fetchThrough(int count) {
    while (fetched < count && fetched < sorted.length) {
      final row = sorted[fetched++].row;
      upstream?.advance(row);
      final projected = _captureWindowProjection(row, projectedColumns);
      for (final state in states.reversed) {
        state.capture(row);
      }
      _freezeWindowProjection(row, projected);
    }
  }

  void advance(RowValues row) {
    var required = 0;
    for (final state in states) {
      final position = state.positions[row]!;
      final group = position.$1;
      final index = position.$2;
      final window = state.expression;
      final key = window.function.key;
      final current =
          sorted.indexWhere((candidate) => identical(candidate.row, row));
      fetchThrough(current + 1);
      state.validateOffsets();
      var last = index;
      if (['row_number', 'lag'].contains(key)) {
        last = index;
      } else if (window.order.isEmpty ||
          window.end.kind == 'UNBOUNDED FOLLOWING' &&
              !['rank', 'dense_rank'].contains(key) ||
          ['lead', 'ntile', 'percent_rank', 'cume_dist'].contains(key)) {
        last = group.length - 1;
      } else if (window.mode != 'ROWS' ||
          ['rank', 'dense_rank'].contains(key)) {
        bool peer(int candidate) {
          for (var i = 0; i < window.order.length; i++) {
            if (compareValues(
                    group[candidate].order[i],
                    group[index].order[i],
                    state.context.encoding,
                    window.order[i].expression.collation(state.context)) !=
                0) {
              return false;
            }
          }
          return true;
        }

        while (last + 1 < group.length && peer(last + 1)) {
          last++;
        }
        if (window.end.kind == 'FOLLOWING') {
          final offset = state.offsets[window.end];
          if (window.mode == 'GROUPS') {
            var remaining = offset as BigInt;
            while (remaining > BigInt.zero && last + 1 < group.length) {
              last++;
              while (last + 1 < group.length) {
                var same = true;
                for (var i = 0; i < window.order.length; i++) {
                  if (compareValues(
                          group[last].order[i],
                          group[last + 1].order[i],
                          state.context.encoding,
                          window.order[i].expression
                              .collation(state.context)) !=
                      0) {
                    same = false;
                    break;
                  }
                }
                if (!same) break;
                last++;
              }
              remaining -= BigInt.one;
            }
          } else {
            final value = group[index].order.single;
            if (value is BigInt || value is double) {
              final term = window.order.single;
              final target = BinaryExpr(term.descending ? '-' : '+',
                      Literal(value), Literal(offset))
                  .evaluate(state.context);
              while (last + 1 < group.length &&
                  term.compare(group[last + 1].order.single, target,
                          state.context) <=
                      0) {
                last++;
              }
            }
          }
        }
      } else if (window.end.kind == 'FOLLOWING') {
        final numericOffset = state.offsets[window.end];
        if (numericOffset is BigInt && numericOffset >= BigInt.zero) {
          final maximum = BigInt.from(group.length);
          last +=
              numericOffset > maximum ? group.length : numericOffset.toInt();
          if (last >= group.length) last = group.length - 1;
        }
      }
      final count = current + (last - index) + 2;
      if (count > required) required = count;
    }
    fetchThrough(required);
  }
}

/// Prepares window input registers independently of the consumer's projection.
/// An ordered scan suspends after the lookahead row; a sorter captures all input
/// registers before it emits the first row.
final class WindowProgram {
  WindowProgram(List<EvalContext> contexts, Iterable<Expr> expressions,
      bool Function(WindowExpr) inputOrdered) {
    if (contexts.length > 10000) {
      throw const SqlException('Window materialization limit exceeded');
    }
    final windows = <WindowExpr>[];
    final projectedColumns = <String>{};
    void visit(Expr expression) {
      if (expression is WindowExpr) {
        if (!windows.contains(expression)) windows.add(expression);
      } else {
        if (expression is ColumnExpr) projectedColumns.add(expression.key);
        for (final child in expression.children) {
          visit(child);
        }
      }
    }

    for (final expression in expressions) {
      visit(expression);
    }
    this.contexts = contexts;
    if (contexts.isEmpty || windows.isEmpty) return;
    final context = contexts.first;
    final rows = contexts.map((ctx) => ctx.row).toList();
    for (final window in windows) {
      final state = _WindowState(window, context, rows, inputOrdered(window));
      context.windowCache[window] = state;
      final shared = _stages
          .where((stage) =>
              _sameWindowDefinition(stage.states.first.expression, window))
          .firstOrNull;
      if (shared != null) {
        shared.states.add(state);
        state.stage = shared;
      } else {
        final stage = _WindowStage([state]);
        state.stage = stage;
        _stages.add(stage);
      }
    }
    for (var i = _stages.length - 1; i >= 0; i--) {
      final stage = _stages[i];
      stage.projectedColumns = projectedColumns;
      stage.upstream = i + 1 < _stages.length ? _stages[i + 1] : null;
      final upstream = stage.upstream;
      final stageRows = upstream == null
          ? rows
          : upstream.sorted.map((row) => row.row).toList();
      final eager = upstream == null
          ? !stage.states.first.streaming
          : !_sameWindowOrder(
              stage.states.first.expression, upstream.states.first.expression);
      final first = stage.states.first;
      if (eager) {
        for (final row in stageRows) {
          upstream?.advance(row);
          final projected = _captureWindowProjection(row, projectedColumns);
          for (final state in stage.states.reversed) {
            state.capture(row);
          }
          // One shared set of partition/order registers belongs to each stage.
          final ctx = first.context.forRow(row);
          first.sorted.add(_WindowRow(
              row,
              first.expression.partition.map((e) => e.evaluate(ctx)).toList(),
              first.expression.order
                  .map((o) => o.expression.evaluate(ctx))
                  .toList(),
              first.sorted.length));
          _freezeWindowProjection(row, projected);
        }
        _sortWindowRows(first);
        stage.fetched = rows.length;
      } else {
        first.keys();
      }
      for (final state in stage.states.skip(1)) {
        state.sorted.addAll(first.sorted);
        state.positions.addAll(first.positions);
      }
    }
    final byRow = {for (final ctx in contexts) ctx.row: ctx};
    this.contexts = _stages.first.sorted.map((row) => byRow[row.row]!).toList();
  }

  late List<EvalContext> contexts;
  final List<_WindowStage> _stages = [];
  void advance(EvalContext context) {
    if (_stages.isNotEmpty) _stages.first.advance(context.row);
  }
}

(String, String, String, String, Expr?, Expr?) _windowFrame(WindowExpr window) {
  switch (window.function.key) {
    case 'row_number':
    case 'lag':
      return (
        'ROWS',
        'UNBOUNDED PRECEDING',
        'CURRENT ROW',
        'NO OTHERS',
        null,
        null
      );
    case 'rank':
    case 'dense_rank':
      return (
        'RANGE',
        'UNBOUNDED PRECEDING',
        'CURRENT ROW',
        'NO OTHERS',
        null,
        null
      );
    case 'lead':
      return (
        'ROWS',
        'UNBOUNDED PRECEDING',
        'UNBOUNDED FOLLOWING',
        'NO OTHERS',
        null,
        null
      );
    case 'ntile':
      return (
        'ROWS',
        'CURRENT ROW',
        'UNBOUNDED FOLLOWING',
        'NO OTHERS',
        null,
        null
      );
    case 'percent_rank':
      return (
        'GROUPS',
        'CURRENT ROW',
        'UNBOUNDED FOLLOWING',
        'NO OTHERS',
        null,
        null
      );
    case 'cume_dist':
      return (
        'GROUPS',
        'FOLLOWING',
        'UNBOUNDED FOLLOWING',
        'NO OTHERS',
        Literal(BigInt.one),
        null
      );
    default:
      return (
        window.mode,
        window.start.kind,
        window.end.kind,
        window.exclusion,
        window.start.offset,
        window.end.offset
      );
  }
}

bool _sameWindowDefinition(WindowExpr a, WindowExpr b) {
  if (!_sameWindowOrder(a, b)) return false;
  final x = _windowFrame(a), y = _windowFrame(b);
  bool offset(Expr? a, Expr? b) =>
      a == null || b == null ? a == b : sameExpression(a, b);
  return x.$1 == y.$1 &&
      x.$2 == y.$2 &&
      x.$3 == y.$3 &&
      x.$4 == y.$4 &&
      offset(x.$5, y.$5) &&
      offset(x.$6, y.$6);
}

bool _sameWindowOrder(WindowExpr a, WindowExpr b) =>
    a.partition.length == b.partition.length &&
    a.order.length == b.order.length &&
    List.generate(a.partition.length, (i) => i)
        .every((i) => sameExpression(a.partition[i], b.partition[i])) &&
    List.generate(a.order.length, (i) => i).every((i) =>
        sameExpression(a.order[i].expression, b.order[i].expression) &&
        a.order[i].descending == b.order[i].descending &&
        a.order[i].nullsFirst == b.order[i].nullsFirst);

void _sortWindowRows(_WindowState state) {
  state.sorted.sort((a, b) {
    final partition = state.comparePartition(a.partition, b.partition);
    if (partition != 0) return partition;
    for (var i = 0; i < state.expression.order.length; i++) {
      final comparison = state.expression.order[i]
          .compare(a.order[i], b.order[i], state.context);
      if (comparison != 0) return comparison;
    }
    return a.ordinal.compareTo(b.ordinal);
  });
  var first = 0;
  while (first < state.sorted.length) {
    var last = first + 1;
    while (last < state.sorted.length &&
        state.comparePartition(
                state.sorted[first].partition, state.sorted[last].partition) ==
            0) {
      last++;
    }
    final group = state.sorted.sublist(first, last);
    for (var i = 0; i < group.length; i++) {
      state.positions[group[i].row] = (group, i);
    }
    first = last;
  }
}

final class _WindowArgument extends Expr {
  _WindowArgument(this.state, this.index, this.source);
  final _WindowState state;
  final int index;
  final Expr source;
  @override
  Object? evaluate(EvalContext context) =>
      state.inputs[context.row]!.arguments[index];
  @override
  String? collation(EvalContext context) => source.collation(context);
}

final class _WindowFilter extends Expr {
  _WindowFilter(this.state);
  final _WindowState state;
  @override
  Object? evaluate(EvalContext context) =>
      state.inputs[context.row]!.accepted ? BigInt.one : BigInt.zero;
}

final class _PercentileWindow {
  _PercentileWindow(String name) : validator = PercentileValidator(name);
  final PercentileValidator validator;
  final Map<RowValues, List<Object?>?> arguments = {};
  var stepped = -1;
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
  bool explicitExclusion = false;
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
        explicitExclusion = base.explicitExclusion;
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
    if (function.registered != null) {
      throw const SqlException('Registered aggregate is not a window function');
    }
    if (function.distinct) {
      throw const SqlException('DISTINCT in window function');
    }
    if (children.any((c) => c.containsWindow)) {
      throw const SqlException('Nested window function');
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

  EvalContext _context(EvalContext source, RowValues row) => source.forRow(row);
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
    final state = context.windowCache[this];
    if (state is! _WindowState) {
      throw const SqlException('Window input was not prepared');
    }
    final positions = state.positions;
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
    Object? arg(int argument, int row) =>
        state.inputs[group[row].row]!.arguments[argument];
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
          final raw = state.offsets[bound];
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
          : state.inputs[frame[target]]!.arguments.first;
    }
    if (percentileFunctionNames.contains(key)) {
      final cache = context.windowCache.putIfAbsent(
              function, () => <List<_WindowRow>, _PercentileWindow>{})
          as Map<List<_WindowRow>, _PercentileWindow>;
      final state = cache.putIfAbsent(group, () => _PercentileWindow(key));
      List<Object?>? argumentsFor(RowValues row) {
        if (state.arguments.containsKey(row)) return state.arguments[row];
        final input = (context.windowCache[this] as _WindowState).inputs[row]!;
        final arguments = input.accepted ? input.arguments : null;
        state.arguments[row] = arguments;
        return arguments;
      }

      if (!explicitExclusion) {
        // Without EXCLUDE the native window retains step state even after an
        // inverse removes all values from its current frame.
        while (state.stepped < last) {
          final args = argumentsFor(group[++state.stepped].row);
          if (args != null) state.validator.step(args);
        }
      }
      return percentileAggregate(
          key, frame.map(argumentsFor).whereType<List<Object?>>(),
          fraction: explicitExclusion ? null : state.validator.fraction);
    }
    final cached = FunctionExpr(
        function.name,
        [
          for (var i = 0; i < function.arguments.length; i++)
            _WindowArgument(state, i, function.arguments[i])
        ],
        star: function.star)
      ..filter = _WindowFilter(state);
    return cached.evaluate(_context(context, current)..group = frame);
  }
}
