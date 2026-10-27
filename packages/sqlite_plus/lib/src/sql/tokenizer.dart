import 'dart:async';

/// Stable classes for callers. The message text is not SQLite's text.
enum SqlErrorCode { constraint, syntax, missingTable }

/// SQL input errors carry their byte-independent Dart string offset.
final class SqlException implements Exception {
  const SqlException(this.message, [this.offset, this.code]);
  final String message;
  final int? offset;
  final SqlErrorCode? code;

  SqlErrorCode? get errorCode => code ?? inferSqlErrorCode(message);

  @override
  String toString() =>
      'SqlException: $message${offset == null ? '' : ' at $offset'}';
}

SqlErrorCode? inferSqlErrorCode(String message) {
  final text = message.toLowerCase();
  if (text.contains('no such table')) return SqlErrorCode.missingTable;
  if (text.contains('constraint')) return SqlErrorCode.constraint;
  if (text.startsWith('expected ') ||
      text.contains('syntax error') ||
      text.contains('unsupported or trailing')) {
    return SqlErrorCode.syntax;
  }
  return null;
}

/// Schemas the current connection accepts in qualified names.
final schemaNamesKey = Object();

/// Collation callbacks for the current connection.
final collationKey = Object();

Set<String> activeSchemaNames() {
  final names = Zone.current[schemaNamesKey];
  if (names is Set<String> && names.isNotEmpty) return names;
  return const {'main'};
}

String _lower(String value) => String.fromCharCodes(
    value.codeUnits.map((unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit));

bool knownCollation(String name) {
  final key = _lower(name);
  if (const {'binary', 'nocase', 'rtrim'}.contains(key)) return true;
  final map = Zone.current[collationKey];
  return map is Map<String, int Function(String, String)> &&
      map.containsKey(key);
}

int? compareRegisteredCollation(String name, String a, String b) {
  final map = Zone.current[collationKey];
  if (map is! Map<String, int Function(String, String)>) return null;
  return map[_lower(name)]?.call(a, b);
}

/// A constraint failure eligible for an SQL conflict policy. Evaluation and
/// callback errors remain SqlException and must not be swallowed by OR IGNORE.
final class SqlConstraintException extends SqlException {
  const SqlConstraintException(super.message,
      [super.offset, this.conflictPolicy = 'ABORT']);
  final String conflictPolicy;
  @override
  SqlErrorCode? get errorCode => SqlErrorCode.constraint;
}

/// STRICT datatype violations always abort, even with OR IGNORE/FAIL.
final class SqlDatatypeConstraint extends SqlConstraintException {
  const SqlDatatypeConstraint(super.message);
}

/// Internal trigger control flow; still an SQL error to API callers.
final class SqlTriggerFailure extends SqlException {
  const SqlTriggerFailure(this.action, super.message);
  final String action;
}

enum SqlTokenKind { identifier, string, number, blob, parameter, symbol, end }

final class SqlToken {
  const SqlToken(this.kind, this.text, this.offset, {this.quoted = false});
  final SqlTokenKind kind;
  final String text;
  final int offset;
  final bool quoted;
  String get keyword => quoted ? '' : text.toUpperCase();
}

/// SQLite-style quoting/comments and bounded SQL tokenization. No execution.
abstract final class SqlTokenizer {
  static List<SqlToken> tokenize(String sql) {
    if (sql.length > 1024 * 1024) {
      throw const SqlException('SQL input exceeds 1 MiB limit');
    }
    final result = <SqlToken>[];
    var i = 0;
    bool identifierStart(int c) =>
        c == 95 || c >= 128 || c >= 65 && c <= 90 || c >= 97 && c <= 122;
    bool digit(int c) => c >= 48 && c <= 57;
    while (i < sql.length) {
      final start = i;
      final c = sql.codeUnitAt(i);
      if (c == 0) throw SqlException('NUL in SQL input', i);
      if ([9, 10, 12, 13, 32].contains(c)) {
        i++;
        continue;
      }
      if (sql.startsWith('--', i)) {
        while (i < sql.length && sql.codeUnitAt(i) != 10) {
          i++;
        }
        continue;
      }
      if (sql.startsWith('/*', i)) {
        final end = sql.indexOf('*/', i + 2);
        if (end < 0) throw SqlException('Unterminated comment', i);
        i = end + 2;
        continue;
      }
      if ((c == 120 || c == 88) && i + 1 < sql.length && sql[i + 1] == "'") {
        final end = sql.indexOf("'", i + 2);
        if (end < 0) throw SqlException('Unterminated blob literal', i);
        final hex = sql.substring(i + 2, end);
        if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
          throw SqlException('Invalid blob literal', i);
        }
        result.add(SqlToken(SqlTokenKind.blob, hex, start));
        i = end + 1;
        continue;
      }
      if ([39, 34, 96, 91].contains(c)) {
        final close = c == 91 ? 93 : c;
        i++;
        final text = StringBuffer();
        var terminated = false;
        while (i < sql.length) {
          final value = sql.codeUnitAt(i++);
          if (value == close) {
            if (c != 91 && i < sql.length && sql.codeUnitAt(i) == close) {
              text.writeCharCode(close);
              i++;
              continue;
            }
            terminated = true;
            break;
          }
          if (value == 0) throw SqlException('NUL in SQL input', i - 1);
          text.writeCharCode(value);
        }
        if (!terminated) throw SqlException('Unterminated quoted token', start);
        result.add(SqlToken(
            c == 39 ? SqlTokenKind.string : SqlTokenKind.identifier,
            text.toString(),
            start,
            quoted: true));
        continue;
      }
      if (digit(c) ||
          c == 46 && i + 1 < sql.length && digit(sql.codeUnitAt(i + 1))) {
        final number = RegExp(
                r'^(?:0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*|(?:[0-9](?:_?[0-9])*(?:\.(?:[0-9](?:_?[0-9])*)?)?|\.[0-9](?:_?[0-9])*)(?:[eE][+-]?[0-9](?:_?[0-9])*)?)')
            .firstMatch(sql.substring(i))!;
        i += number.end;
        if (i < sql.length && identifierStart(sql.codeUnitAt(i))) {
          throw SqlException('Invalid numeric literal', start);
        }
        result.add(SqlToken(SqlTokenKind.number, number[0]!, start));
        continue;
      }
      if (identifierStart(c)) {
        i++;
        while (i < sql.length &&
            (identifierStart(sql.codeUnitAt(i)) ||
                digit(sql.codeUnitAt(i)) ||
                sql.codeUnitAt(i) == 36)) {
          i++;
        }
        result.add(
            SqlToken(SqlTokenKind.identifier, sql.substring(start, i), start));
        continue;
      }
      if (c == 63) {
        i++;
        while (i < sql.length && digit(sql.codeUnitAt(i))) {
          i++;
        }
        result.add(
            SqlToken(SqlTokenKind.parameter, sql.substring(start, i), start));
        continue;
      }
      if (c == 58 || c == 64 || c == 36) {
        i++;
        var nameUnits = 0;
        while (i < sql.length) {
          final current = sql.codeUnitAt(i);
          if (identifierStart(current) || digit(current) || current == 36) {
            nameUnits++;
            i++;
            continue;
          }
          if (current == 58 &&
              i + 1 < sql.length &&
              sql.codeUnitAt(i + 1) == 58) {
            i += 2;
            continue;
          }
          if (current == 40 && nameUnits > 0) {
            i++;
            while (i < sql.length &&
                sql.codeUnitAt(i) > 32 &&
                sql.codeUnitAt(i) != 41) {
              i++;
            }
            if (i >= sql.length || sql.codeUnitAt(i) != 41) {
              throw SqlException('Invalid parameter suffix', start);
            }
            i++;
          }
          break;
        }
        if (nameUnits == 0) throw SqlException('Missing parameter name', start);
        result.add(
            SqlToken(SqlTokenKind.parameter, sql.substring(start, i), start));
        continue;
      }
      if (i + 2 < sql.length && sql.startsWith('->>', i)) {
        result.add(SqlToken(SqlTokenKind.symbol, '->>', start));
        i += 3;
        continue;
      }
      final pair = i + 1 < sql.length ? sql.substring(i, i + 2) : '';
      if (pair == '->' ||
          ['<=', '>=', '!=', '<>', '==', '||', '<<', '>>'].contains(pair)) {
        result.add(SqlToken(SqlTokenKind.symbol, pair, start));
        i += 2;
      } else if ('(),;.*+-/%=<>~&|'.contains(sql[i])) {
        result.add(SqlToken(SqlTokenKind.symbol, sql[i++], start));
      } else {
        throw SqlException('Unsupported token ${sql[i]}', i);
      }
    }
    result.add(SqlToken(SqlTokenKind.end, '', sql.length));
    return List.unmodifiable(result);
  }
}
