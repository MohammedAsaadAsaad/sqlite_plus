/// Quotes a SQL identifier.
String quoteIdent(String name) => '"${name.replaceAll('"', '""')}"';

/// A name `PRAGMA table_info` accepts without extra quotes.
String pragmaIdent(String name) {
  if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) return name;
  return quoteIdent(name);
}

/// The statement returns rows. `PRAGMA` assignments are included and retried
/// as writes when the engine rejects the read.
bool statementReads(String sql) {
  final words = sqlWords(sql);
  if (words.isEmpty) return true;
  final first = words.first;
  if (first == 'select' ||
      first == 'values' ||
      first == 'explain' ||
      first == 'pragma') {
    return true;
  }
  if (first == 'with') {
    return !words.any(
      (word) =>
          word == 'insert' ||
          word == 'update' ||
          word == 'delete' ||
          word == 'replace',
    );
  }
  return false;
}

/// True when the outer statement has `LIMIT`, ignoring limits inside
/// parentheses, quotes, and comments.
bool outerSqlLimit(String sql) {
  var depth = 0;
  String? quote;
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) {
        final doubled = i + 1 < sql.length && sql[i + 1] == quote;
        if (doubled) {
          i++;
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (char == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      final end = sql.indexOf('\n', i);
      i = end < 0 ? sql.length - 1 : end;
      continue;
    }
    if (char == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      final end = sql.indexOf('*/', i + 2);
      i = end < 0 ? sql.length - 1 : end + 1;
      continue;
    }
    if (char == '(') {
      depth++;
      continue;
    }
    if (char == ')') {
      if (depth > 0) depth--;
      continue;
    }
    if (depth == 0 && _keywordAt(sql, i, 'limit')) return true;
  }
  return false;
}

bool _keywordAt(String sql, int index, String word) {
  if (index > 0 && _sqlIdent(sql.codeUnitAt(index - 1))) return false;
  final end = index + word.length;
  if (end > sql.length) return false;
  if (sql.substring(index, end).toLowerCase() != word) return false;
  if (end < sql.length && _sqlIdent(sql.codeUnitAt(end))) return false;
  return true;
}

bool _sqlIdent(int unit) {
  if (unit == 95) return true;
  if (unit >= 48 && unit <= 57) return true;
  if (unit >= 65 && unit <= 90) return true;
  if (unit >= 97 && unit <= 122) return true;
  return unit > 127;
}

/// Lower-case words outside quotes.
List<String> sqlWords(String sql) {
  final words = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) {
        final doubled = i + 1 < sql.length && sql[i + 1] == quote;
        if (doubled) {
          i++;
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      _flush(words, buffer);
      quote = char;
      continue;
    }
    final letter = RegExp(r'[A-Za-z_]').hasMatch(char);
    if (letter) {
      buffer.write(char.toLowerCase());
    } else {
      _flush(words, buffer);
    }
  }
  _flush(words, buffer);
  return words;
}

void _flush(List<String> words, StringBuffer buffer) {
  if (buffer.isEmpty) return;
  words.add(buffer.toString());
  buffer.clear();
}

/// Cell text for the grid. Null is the word NULL.
String formatCell(Object? value) {
  if (value == null) return 'NULL';
  if (value is BigInt || value is num || value is bool) return '$value';
  if (value is List<int>) return 'bytes(${value.length})';
  return value.toString();
}

/// Parses a typed cell. Blank text is NULL.
Object? parseCell(String text, {required bool nullWord}) {
  if (nullWord) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (RegExp(r'^-?\d+$').hasMatch(trimmed)) return BigInt.parse(trimmed);
  if (RegExp(r'^-?\d+\.\d+$').hasMatch(trimmed)) return double.parse(trimmed);
  return text;
}

/// How the cell editor presents a declared column type.
enum CellKind { integer, real, text, boolean, date, time, dateTime }

/// The editor shape for a declared SQL type.
CellKind cellKind(String declared) {
  final type = declared.toUpperCase();
  if (type.contains('BOOL')) return CellKind.boolean;
  if (type.contains('DATETIME') || type.contains('TIMESTAMP')) {
    return CellKind.dateTime;
  }
  if (type.contains('DATE')) return CellKind.date;
  if (RegExp(r'(^|[^A-Z])TIME([^A-Z]|$)').hasMatch(type)) return CellKind.time;
  if (type.contains('INT')) return CellKind.integer;
  if (type.contains('REAL') ||
      type.contains('FLOA') ||
      type.contains('DOUB') ||
      type.contains('DEC') ||
      type.contains('NUM')) {
    return CellKind.real;
  }
  return CellKind.text;
}

/// True when [text] can be stored in a column of [kind]. Blank text is NULL.
bool cellTextValid(String text, CellKind kind) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return true;
  switch (kind) {
    case CellKind.integer:
    case CellKind.boolean:
      return RegExp(r'^-?\d+$').hasMatch(trimmed);
    case CellKind.real:
      final value = double.tryParse(trimmed);
      return value != null && value.isFinite;
    case CellKind.text:
    case CellKind.date:
    case CellKind.time:
    case CellKind.dateTime:
      return true;
  }
}

/// Parses [text] for a column of [kind]. Numbers stay numbers. Text stays text.
Object? parseTypedCell(String text, CellKind kind, {required bool nullWord}) {
  if (nullWord) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  switch (kind) {
    case CellKind.integer:
    case CellKind.boolean:
      return BigInt.parse(trimmed);
    case CellKind.real:
      if (RegExp(r'^-?\d+$').hasMatch(trimmed)) return BigInt.parse(trimmed);
      return double.parse(trimmed);
    case CellKind.text:
    case CellKind.date:
    case CellKind.time:
    case CellKind.dateTime:
      return text;
  }
}

/// Editor text for a value. NULL starts blank.
String editableText(Object? value) {
  if (value == null || value is List<int>) return '';
  return '$value';
}

/// A file size in bytes, shown as B, KB, or MB.
String formatBytes(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return kb == kb.roundToDouble()
        ? '${kb.toInt()} KB'
        : '${kb.toStringAsFixed(1)} KB';
  }
  final mb = bytes / (1024 * 1024);
  return mb == mb.roundToDouble()
      ? '${mb.toInt()} MB'
      : '${mb.toStringAsFixed(1)} MB';
}
