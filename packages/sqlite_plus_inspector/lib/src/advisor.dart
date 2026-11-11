part of '../sqlite_plus_inspector.dart';

final class IndexAdviceOptions {
  const IndexAdviceOptions(
      {this.samples = 3,
      this.maxImageBytes = 32 * 1024 * 1024,
      this.maxRows = 10000,
      this.maxSqlChars = 16384});
  final int samples, maxImageBytes, maxRows, maxSqlChars;
  void _validate() {
    if (samples < 1 ||
        samples > 7 ||
        maxImageBytes < 512 ||
        maxRows < 1 ||
        maxSqlChars < 1 ||
        maxSqlChars > 65536) {
      throw ArgumentError('Invalid advice limits');
    }
  }
}

final class IndexAdvice {
  IndexAdvice._(
      this.table,
      this.indexName,
      this.createSql,
      List<String> columns,
      this.before,
      this.after,
      List<Duration> beforeTimes,
      List<Duration> afterTimes,
      this.buildDuration,
      this.beforeBytes,
      this.afterBytes)
      : columns = List.unmodifiable(columns),
        beforeTimes = List.unmodifiable(beforeTimes),
        afterTimes = List.unmodifiable(afterTimes);
  final String table, indexName, createSql;
  final List<String> columns;
  final InspectorPlan before, after;
  final List<Duration> beforeTimes, afterTimes;
  final Duration buildDuration;
  final int beforeBytes, afterBytes;
  bool get selectedByPlanner => after.indexName == indexName;
  int get addedBytes => afterBytes - beforeBytes;
  bool get writeCostMeasured => false;
}

final class IndexAdviceReport {
  IndexAdviceReport._(this.reason, this.advice);
  final String reason;
  final IndexAdvice? advice;
}

String _adviceQuote(String text) => '"${text.replaceAll('"', '""')}"';
String _adviceLower(String text) => String.fromCharCodes(
    text.codeUnits.map((x) => x >= 65 && x <= 90 ? x + 32 : x));

/// Deliberately narrow tokenizer grammar, independent of private engine ASTs.
final class _AdviceSelect {
  _AdviceSelect(String sql)
      : tokens = SqlTokenizer.tokenize(sql)
            .where((t) => t.kind != SqlTokenKind.end)
            .toList();
  final List<SqlToken> tokens;
  int pos = 0;
  String table = '', alias = '';
  final equal = <String>[], range = <String>[];
  final order = <(String, bool)>[];
  final referenced = <String>[];
  bool take(String word) {
    if (pos < tokens.length &&
        (tokens[pos].keyword == word ||
            tokens[pos].kind != SqlTokenKind.identifier &&
                tokens[pos].text == word)) {
      pos++;
      return true;
    }
    return false;
  }

  Never fail() => throw const FormatException(
      'Advisor supports simple single-table SELECT with AND comparisons and column ORDER BY only');
  String ident() {
    if (pos >= tokens.length || tokens[pos].kind != SqlTokenKind.identifier) {
      fail();
    }
    return tokens[pos++].text;
  }

  String column() {
    var name = ident();
    if (take('.')) {
      final qualifier = name;
      name = ident();
      if (table.isNotEmpty &&
          _adviceLower(qualifier) != _adviceLower(table) &&
          _adviceLower(qualifier) != _adviceLower(alias)) {
        fail();
      }
    }
    referenced.add(name);
    return name;
  }

  void value() {
    final negative = take('-') || take('+');
    if (pos >= tokens.length) fail();
    final t = tokens[pos++];
    if (negative && t.kind != SqlTokenKind.number) fail();
    if (![
          SqlTokenKind.parameter,
          SqlTokenKind.number,
          SqlTokenKind.string,
          SqlTokenKind.blob
        ].contains(t.kind) &&
        t.keyword != 'NULL') {
      fail();
    }
  }

  void condition() {
    if (take('(')) {
      conjunction();
      if (!take(')')) fail();
      return;
    }
    final name = column();
    if (pos >= tokens.length) fail();
    final op = tokens[pos++].text;
    if (!['=', '==', '>', '>=', '<', '<='].contains(op)) fail();
    value();
    (op == '=' || op == '==' ? equal : range).add(name);
  }

  void conjunction() {
    condition();
    while (take('AND')) {
      condition();
    }
  }

  void parse() {
    if (!take('SELECT')) fail();
    if (!take('*')) {
      column();
      while (take(',')) {
        column();
      }
    }
    if (!take('FROM')) fail();
    table = ident();
    if (take('.')) {
      if (_adviceLower(table) != 'main') fail();
      table = ident();
    }
    if (take('AS')) {
      alias = ident();
    } else if (pos < tokens.length &&
        tokens[pos].kind == SqlTokenKind.identifier &&
        !['WHERE', 'ORDER'].contains(tokens[pos].keyword)) {
      alias = ident();
    }
    if (take('WHERE')) conjunction();
    if (take('ORDER')) {
      if (!take('BY')) fail();
      do {
        final name = column();
        final desc = take('DESC');
        if (!desc) take('ASC');
        order.add((name, desc));
      } while (take(','));
    }
    take(';');
    if (pos != tokens.length) fail();
  }
}

extension InspectorIndexAdvice on SqlInspector {
  /// Builds and measures one candidate only on a disposable main-image copy.
  /// Original query execution and diagnostic sampling require explicit invocation.
  Future<IndexAdviceReport> adviseIndex(
      MutableSqliteDatabase database, String sql,
      {List<Object?> parameters = const [],
      IndexAdviceOptions options = const IndexAdviceOptions()}) async {
    options._validate();
    if (sql.length > options.maxSqlChars || parameters.length > 1000) {
      throw ArgumentError('Advice SQL/parameter budget exceeded');
    }
    final parsed = _AdviceSelect(sql);
    try {
      parsed.parse();
    } on FormatException catch (e) {
      return IndexAdviceReport._(e.message, null);
    }
    if (database.inTransaction) {
      throw StateError('Finish caller transaction before advice');
    }
    final image = database.exportImage();
    if (image.length > options.maxImageBytes) {
      throw StateError('Advice image budget exceeded');
    }
    final args = parameters.map(copyDiagnosticValue).toList();
    final clone = await MutableSqliteDatabase.fromImage(image);
    try {
      final schema = await clone.query(
          "SELECT sql FROM sqlite_schema WHERE type='table' AND name=?",
          [parsed.table]);
      if (schema.rows.isEmpty) {
        return IndexAdviceReport._('Ordinary main table required', null);
      }
      final ddl = schema.rows.single.single as String;
      if (ddl.toUpperCase().contains('VIRTUAL TABLE')) {
        return IndexAdviceReport._('Virtual table advice is unsupported', null);
      }
      final table = DatabaseCatalog.parseTable(ddl, 1);
      final names = {
        for (final c in table.columns) _adviceLower(c.name): c.name
      };
      if (parsed.referenced.any((n) => !names.containsKey(_adviceLower(n)))) {
        return IndexAdviceReport._(
            'Unknown or unsupported column reference', null);
      }
      final columns = <(String, bool)>[];
      void add(String name, bool desc) {
        final actual = names[_adviceLower(name)]!;
        if (!columns.any((c) => c.$1 == actual)) columns.add((actual, desc));
      }

      for (final name in parsed.equal) {
        add(name, false);
      }
      if (parsed.range.isNotEmpty) add(parsed.range.first, false);
      for (final item in parsed.order) {
        add(item.$1, item.$2);
      }
      if (columns.isEmpty || columns.length > 8) {
        return IndexAdviceReport._('No bounded index candidate', null);
      }
      if (columns.any((c) =>
          table.columns
              .firstWhere((x) => x.name == c.$1)
              .collation
              .toLowerCase() !=
          'binary')) {
        return IndexAdviceReport._(
            'Advice currently requires BINARY candidate collations', null);
      }
      final count = (await clone
              .query('SELECT count(*) FROM ${_adviceQuote(parsed.table)}'))
          .rows
          .single
          .single as BigInt;
      if (count > BigInt.from(options.maxRows)) {
        throw StateError('Advice row budget exceeded');
      }
      final before = await inspectDatabasePlan(clone, sql, args);
      if (before.hasRowidBound) {
        return IndexAdviceReport._(
            'Primary-key point access already selected', null);
      }
      final indexes = await clone
          .query('SELECT * FROM pragma_index_list(?)', [parsed.table]);
      for (final raw in indexes.rows) {
        if (raw[4] != BigInt.zero) continue;
        final info =
            await clone.query('SELECT * FROM pragma_index_xinfo(?)', [raw[1]]);
        final keys = info.rows.where((r) => r[5] == BigInt.one).toList();
        if (keys.length >= columns.length &&
            List.generate(
                    columns.length,
                    (i) =>
                        keys[i][2] == columns[i].$1 &&
                        (keys[i][3] == BigInt.one) == columns[i].$2 &&
                        (keys[i][4] as String).toLowerCase() == 'binary')
                .every((v) => v)) {
          return IndexAdviceReport._(
              'Equivalent ordinary index prefix already exists', null);
        }
      }
      final name = '_spi_advice_${sha256.convert(utf8.encode(jsonEncode([
                parsed.table,
                columns.map((c) => [c.$1, c.$2]).toList()
              ]))).toString().substring(0, 16)}';
      if ((await clone
              .query('SELECT name FROM sqlite_schema WHERE name=?', [name]))
          .rows
          .isNotEmpty) {
        return IndexAdviceReport._('Candidate name already occupied', null);
      }
      final create =
          'CREATE INDEX ${_adviceQuote(name)} ON ${_adviceQuote(parsed.table)} (${columns.map((c) => '${_adviceQuote(c.$1)} ${c.$2 ? 'DESC' : 'ASC'}').join(',')})';
      String? proof;
      Future<List<Duration>> sample() async {
        final times = <Duration>[];
        for (var i = 0; i < options.samples; i++) {
          final watch = Stopwatch()..start();
          final result = await clone.query(sql, args);
          watch.stop();
          final hash = queryProof(result, unordered: true);
          if (proof != null && proof != hash) {
            throw StateError('Candidate query result multiset diverged');
          }
          proof = hash;
          times.add(watch.elapsed);
        }
        return times;
      }

      final beforeTimes = await sample();
      final clock = Stopwatch()..start();
      await clone.execute(create);
      clock.stop();
      final afterBytes = clone.exportImage().length;
      if (afterBytes > options.maxImageBytes) {
        throw StateError('Candidate image budget exceeded');
      }
      final after = await inspectDatabasePlan(clone, sql, args);
      final afterTimes = await sample();
      return IndexAdviceReport._(
          'Measured candidate on isolated copy; workload-wide benefit and write cost are unverified',
          IndexAdvice._(
              parsed.table,
              name,
              create,
              columns.map((c) => c.$1).toList(),
              before,
              after,
              beforeTimes,
              afterTimes,
              clock.elapsed,
              image.length,
              afterBytes));
    } finally {
      await clone.close();
    }
  }
}
