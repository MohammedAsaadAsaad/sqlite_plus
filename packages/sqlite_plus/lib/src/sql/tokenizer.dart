/// SQL input errors carry their byte-independent Dart string offset.
final class SqlException implements Exception {
  const SqlException(this.message, [this.offset]);
  final String message;
  final int? offset;
  @override
  String toString() =>
      'SqlException: $message${offset == null ? '' : ' at $offset'}';
}

/// A constraint failure eligible for an SQL conflict policy. Evaluation and
/// callback errors remain SqlException and must not be swallowed by OR IGNORE.
final class SqlConstraintException extends SqlException {
  const SqlConstraintException(super.message, [super.offset]);
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
                r'^(?:0[xX][0-9a-fA-F]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')
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
      final pair = i + 1 < sql.length ? sql.substring(i, i + 2) : '';
      if (['<=', '>=', '!=', '<>', '==', '||', '<<', '>>'].contains(pair)) {
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
