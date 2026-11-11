part of 'database.dart';

/// Bounds retained diagnostic metadata, not SQL input/result allocations.
final class SqlDiagnosticOptions {
  const SqlDiagnosticOptions({this.maxCandidates = 64});
  final int maxCandidates;
}

String _diagnosticName(String value) =>
    String.fromCharCodes(value.runes.take(128));

/// One actually enumerated planner alternative. Missing estimates stay null.
final class SqlPlanDecision {
  SqlPlanDecision._(this.ordinal, String? indexName, this.access, this.eligible,
      this.reason, this.estimatedRows, this.prefixScore)
      : indexName = indexName == null ? null : _diagnosticName(indexName);
  final int ordinal;
  final String? indexName;
  final String access, reason;
  final bool eligible;
  final double? estimatedRows;
  final int? prefixScore;
  Map<String, Object?> toJson() => {
        'ordinal': ordinal,
        'indexName': indexName,
        'access': access,
        'eligible': eligible,
        'reason': reason,
        'estimatedRows': estimatedRows,
        'prefixScore': prefixScore,
      };
}

/// Immutable plan metadata, deliberately without executable closures/bindings.
final class SqlDiagnosticPlan {
  SqlDiagnosticPlan._(QueryPlan plan)
      : access = plan.access,
        indexName =
            plan.indexName == null ? null : _diagnosticName(plan.indexName!),
        rootPage = plan.rootPage,
        covering = plan.covering;
  final String access;
  final String? indexName;
  final int? rootPage;
  final bool covering;
  Map<String, Object?> toJson() => {
        'access': access,
        'indexName': indexName,
        'rootPage': rootPage,
        'covering': covering,
      };
}

/// Explicit query result and bounded measurements. JSON excludes result data,
/// SQL text, bindings and point-lookup values. Loan the reader exclusively while
/// measuring: page reads are a connection-wide pager delta. Source preparation
/// includes planning, reads and evaluator metadata; planningTime is its measured
/// planner-only subset. parseAndSupportValidationTime is not full SQL validation.
final class SqlQueryDiagnostics {
  SqlQueryDiagnostics._(
      this.result,
      _SqlDiagnosticTrace trace,
      this.parseAndSupportValidationTime,
      this.sourcePreparationTime,
      this.evaluationTime,
      this.totalTime,
      this.pageReads)
      : plan = trace.plan!,
        decisions = List.unmodifiable(trace.decisions),
        enumeratedCandidates = trace.enumerated,
        selectedOrdinal = trace.selected,
        estimatedRows = trace.selectedEstimate,
        planningTime = trace.planningClock.elapsed,
        rowsLoaded = trace.loaded,
        rowsVisited = trace.visited,
        rowsMatched = trace.matched,
        sortStrategy = trace.sortStrategy,
        peakSortRows = trace.peakSortRows;
  final QueryResult result;
  final SqlDiagnosticPlan plan;
  final List<SqlPlanDecision> decisions;
  final int enumeratedCandidates;
  final int? selectedOrdinal;
  final double? estimatedRows;
  final Duration parseAndSupportValidationTime,
      planningTime,
      sourcePreparationTime,
      evaluationTime,
      totalTime;
  final int pageReads, rowsLoaded, rowsVisited, rowsMatched;
  final String sortStrategy;
  final int? peakSortRows;
  bool get decisionsTruncated => enumeratedCandidates > decisions.length;
  bool get selectedDecisionCaptured =>
      decisions.any((d) => d.ordinal == selectedOrdinal);
  Map<String, Object?> toJson() => {
        'version': 1,
        'plan': plan.toJson(),
        'decisions': decisions.map((d) => d.toJson()).toList(),
        'enumeratedCandidates': enumeratedCandidates,
        'decisionsTruncated': decisionsTruncated,
        'selectedOrdinal': selectedOrdinal,
        'selectedDecisionCaptured': selectedDecisionCaptured,
        'estimatedRows': estimatedRows,
        'parseAndSupportValidationUs':
            parseAndSupportValidationTime.inMicroseconds,
        'planningUs': planningTime.inMicroseconds,
        'sourcePreparationUs': sourcePreparationTime.inMicroseconds,
        'evaluationUs': evaluationTime.inMicroseconds,
        'totalUs': totalTime.inMicroseconds,
        'pageReads': pageReads,
        'rowsLoaded': rowsLoaded,
        'rowsVisited': rowsVisited,
        'rowsMatched': rowsMatched,
        'rowsReturned': result.rows.length,
        'sortStrategy': sortStrategy,
        'peakSortRows': peakSortRows,
        'requiresExclusiveReader': true,
        'indexKeysExamined': null,
        'sortComparisons': null,
        'projectionCalls': null,
        'allocatedBytes': null,
        'scope': 'ordinary-single-source',
        'estimationModel': 'existing-rules-and-optional-STAT1',
      };
}

final class _SqlDiagnosticTrace {
  _SqlDiagnosticTrace(this.capacity);
  final int capacity;
  final decisions = <SqlPlanDecision>[];
  final planningClock = Stopwatch();
  int enumerated = 0, loaded = 0, visited = 0, matched = 0;
  int? selected;
  double? selectedEstimate;
  SqlDiagnosticPlan? plan;
  bool hasOrder = false,
      inputOrdered = false,
      distinct = false,
      bounded = false;
  int? limit;
  int offset = 0;
  int record(String access, String reason,
      {String? index,
      bool eligible = true,
      double? estimate,
      int? score,
      bool chosen = false}) {
    final ordinal = enumerated++;
    if (decisions.length < capacity) {
      decisions.add(SqlPlanDecision._(
          ordinal, index, access, eligible, reason, estimate, score));
    }
    if (chosen) select(ordinal, estimate);
    return ordinal;
  }

  void select(int ordinal, double? estimate) {
    selected = ordinal;
    selectedEstimate = estimate;
  }

  Iterable<RowValues> source(Iterable<RowValues> input) sync* {
    for (final row in input) {
      visited++;
      yield row;
    }
  }

  Iterable<RowValues> matches(Iterable<RowValues> input) sync* {
    for (final row in input) {
      matched++;
      yield row;
    }
  }

  String get sortStrategy {
    if (!hasOrder) return inputOrdered ? 'input-order' : 'none';
    if (limit == 0) return 'none';
    if (distinct) return 'full-sort-distinct';
    final k = limit;
    if (!bounded || k == null || k < 0) return 'full-sort';
    final capacity = k + (offset > 0 ? offset : 0);
    if (matched <= capacity) return 'retained-sort';
    return capacity >= 32 ? 'bounded-heap' : 'bounded-linear';
  }

  int? get peakSortRows {
    if (distinct) return null;
    if (!hasOrder || limit == 0) return 0;
    final k = limit;
    if (!bounded || k == null || k < 0) return matched;
    final capacity = k + (offset > 0 ? offset : 0);
    return matched < capacity ? matched : capacity;
  }
}

bool _unsupportedDiagnosticExpression(Expr expression) {
  if (expression is SubqueryExpr ||
      expression is InSelectExpr ||
      expression.containsAggregate ||
      expression.containsWindow) {
    return true;
  }
  // Empty IN has no children for evaluation purposes; still inspect its operand
  // when deciding the supported diagnostic boundary.
  if (expression is InExpr) {
    return _unsupportedDiagnosticExpression(expression.operand) ||
        expression.values.any(_unsupportedDiagnosticExpression);
  }
  return expression.children.any(_unsupportedDiagnosticExpression);
}

extension SqlReadDiagnostics on SqliteDatabase {
  /// Executes once with explicit bounded diagnostics. Unsupported shapes reject
  /// before SQL callbacks. Normal query/prepare paths retain their SQL coverage.
  Future<SqlQueryDiagnostics> diagnoseQuery(String sql,
      {List<Object?> parameters = const [],
      SqlDiagnosticOptions options = const SqlDiagnosticOptions()}) {
    try {
      if (options.maxCandidates < 0 || options.maxCandidates > 256) {
        throw ArgumentError('maxCandidates must be 0..256');
      }
      if (sql.length > 65536) {
        throw UnsupportedError('Diagnostic SQL exceeds 65536 code units');
      }
      final bound = List<Object?>.unmodifiable(parameters.map(sqlValue));
      return functions.run(() async {
        if (_closed) throw StateError('Database is closed');
        final total = Stopwatch()..start();
        final parse = Stopwatch()..start();
        final parser = SqlParser(sql);
        if (parser.current.keyword != 'SELECT') {
          throw UnsupportedError('Diagnosis supports ordinary SELECT only');
        }
        final statement = parser.select();
        if (bound.length != statement.parameterCount) {
          throw const SqlException('Incorrect parameter count');
        }
        final expressions = [
          ...statement.items.map((i) => i.expression).whereType<Expr>(),
          ...statement.order.map((o) => o.expression),
          if (statement.where != null) statement.where!,
          if (statement.limit != null) statement.limit!,
          if (statement.offset != null) statement.offset!,
        ];
        if (_needsRelational(statement) ||
            statement.valuesQuery ||
            statement.groupBy.isNotEmpty ||
            statement.having != null ||
            statement.windowDefinitions.isNotEmpty ||
            expressions.any(_unsupportedDiagnosticExpression)) {
          throw UnsupportedError('Diagnosis requires a simple scalar SELECT');
        }
        final table =
            statement.table == null ? null : catalog.table(statement.table!);
        if (table != null &&
            (table.virtual ||
                table.columns.any((c) => c.generatedExpression != null))) {
          throw UnsupportedError(
              'Diagnosis requires an ordinary non-generated source');
        }
        parse.stop();
        final trace = _SqlDiagnosticTrace(options.maxCandidates);
        final pagesBefore = pagesRead;
        final preparation = Stopwatch()..start();
        final execution =
            await _prepareQuery(sql, bound, null, statement, trace);
        preparation.stop();
        final evaluation = Stopwatch()..start();
        final result = execution.materialize();
        evaluation.stop();
        total.stop();
        return SqlQueryDiagnostics._(
            result,
            trace,
            parse.elapsed,
            preparation.elapsed,
            evaluation.elapsed,
            total.elapsed,
            pagesRead - pagesBefore);
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }
}
