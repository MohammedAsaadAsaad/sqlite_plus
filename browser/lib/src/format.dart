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

/// Editor text for a value. NULL starts blank.
String editableText(Object? value) {
  if (value == null || value is List<int>) return '';
  return '$value';
}
