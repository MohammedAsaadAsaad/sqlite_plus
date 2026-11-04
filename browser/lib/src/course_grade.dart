import 'package:sqlite_plus/sqlite_plus.dart';

import 'course_models.dart';
import 'format.dart';

/// A small result table ready to show.
class QueryTable {
  const QueryTable({required this.columns, required this.rows});

  final List<String> columns;
  final List<List<String>> rows;

  static const empty = QueryTable(columns: [], rows: []);
}

/// The outcome of checking one statement.
class SqlGrade {
  const SqlGrade({
    required this.passed,
    required this.message,
    required this.actual,
    required this.expected,
  });

  final bool passed;
  final String message;
  final QueryTable actual;
  final QueryTable expected;

  const SqlGrade.fail(String message)
      : this(
          passed: false,
          message: message,
          actual: QueryTable.empty,
          expected: QueryTable.empty,
        );
}

/// Splits [sql] on semicolons that are outside quotes and comments.
List<String> splitSql(String sql) {
  final parts = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote != null) {
      buffer.write(char);
      if (char == quote) {
        final doubled = i + 1 < sql.length && sql[i + 1] == quote;
        if (doubled) {
          buffer.write(sql[++i]);
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      buffer.write(char);
      continue;
    }
    if (char == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      while (i < sql.length && sql[i] != '\n') {
        i++;
      }
      continue;
    }
    if (char == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      i += 2;
      while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
        i++;
      }
      if (i + 1 < sql.length) i++;
      continue;
    }
    if (char == ';') {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) parts.add(text);
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  final tail = buffer.toString().trim();
  if (tail.isNotEmpty) parts.add(tail);
  return parts;
}

/// Runs an example and returns the result the lesson displays.
Future<QueryTable> runExample(SqlExample example) {
  return _capture(example.setup, example.statement, example.probe);
}

/// The rows a task shows before the learner changes them.
Future<QueryTable> previewTable(SqlTask task) {
  final preview = task.preview;
  if (preview == null) return Future.value(QueryTable.empty);
  return _capture(task.setup, preview, null);
}

/// The result a correct statement produces for [task].
Future<QueryTable> expectedTable(SqlTask task) {
  return _capture(task.setup, task.statement, task.probe);
}

/// Runs [attempt] on a fresh database and compares it with [task].
Future<SqlGrade> gradeSql(SqlTask task, String attempt) async {
  final statements = splitSql(attempt);
  if (statements.isEmpty) return const SqlGrade.fail('Write a statement.');
  if (statements.length != 1) {
    return const SqlGrade.fail('Write one statement.');
  }
  final student = statements.single;
  final changes = task.probe != null;
  if (changes && statementReads(student)) {
    return const SqlGrade.fail(
      'This step changes rows. Write the change, not a query.',
    );
  }
  if (!changes && !statementReads(student)) {
    return const SqlGrade.fail('This step is a query. Write a SELECT.');
  }
  final QueryTable expected;
  try {
    expected = await expectedTable(task);
  } on SqlException catch (error) {
    return SqlGrade.fail(error.message);
  }
  final QueryTable actual;
  try {
    actual = await _capture(task.setup, student, task.probe);
  } on SqlException catch (error) {
    return SqlGrade(
      passed: false,
      message: error.message,
      actual: QueryTable.empty,
      expected: expected,
    );
  }
  if (!_sameTable(expected, actual, task.orderMatters)) {
    return SqlGrade(
      passed: false,
      message: 'The result does not match.',
      actual: actual,
      expected: expected,
    );
  }
  return SqlGrade(
    passed: true,
    message: 'Passed',
    actual: actual,
    expected: expected,
  );
}

Future<QueryTable> _capture(
  String setup,
  String statement,
  String? probe,
) async {
  final database = await MutableSqliteDatabase.create();
  try {
    await _runScript(database, setup);
    if (probe == null) {
      final result = await database.query(statement);
      return _table(result);
    }
    await _runOne(database, statement);
    final steps = splitSql(probe);
    if (steps.isEmpty) {
      throw const SqlException('The check has no query.');
    }
    for (final step in steps.take(steps.length - 1)) {
      await _runOne(database, step);
    }
    final result = await database.query(steps.last);
    return _table(result);
  } finally {
    await database.close();
  }
}

Future<void> _runScript(MutableSqliteDatabase database, String script) async {
  for (final statement in splitSql(script)) {
    await _runOne(database, statement);
  }
}

Future<void> _runOne(MutableSqliteDatabase database, String statement) async {
  if (statementReads(statement)) {
    await database.query(statement);
    return;
  }
  await database.execute(statement);
}

QueryTable _table(QueryResult result) {
  return QueryTable(
    columns: result.columns,
    rows: [
      for (final row in result.rows) [for (final value in row) _cell(value)],
    ],
  );
}

String _cell(Object? value) {
  if (value == null) return 'NULL';
  if (value is double && value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toString();
}

bool _sameTable(QueryTable expected, QueryTable actual, bool orderMatters) {
  if (expected.columns.length != actual.columns.length) return false;
  if (expected.rows.length != actual.rows.length) return false;
  for (var i = 0; i < expected.columns.length; i++) {
    if (expected.columns[i].toLowerCase() != actual.columns[i].toLowerCase()) {
      return false;
    }
  }
  final left = orderMatters ? expected.rows : _sorted(expected.rows);
  final right = orderMatters ? actual.rows : _sorted(actual.rows);
  for (var row = 0; row < left.length; row++) {
    for (var column = 0; column < left[row].length; column++) {
      if (left[row][column] != right[row][column]) return false;
    }
  }
  return true;
}

List<List<String>> _sorted(List<List<String>> rows) {
  final copy = [
    for (final row in rows) [...row],
  ];
  copy.sort((a, b) => a.join('\u0001').compareTo(b.join('\u0001')));
  return copy;
}
