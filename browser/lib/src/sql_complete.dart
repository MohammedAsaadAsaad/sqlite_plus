import 'format.dart';
import 'session.dart';

/// One completion for the word at the cursor.
class SqlCompletion {
  const SqlCompletion({
    required this.label,
    required this.insert,
    required this.kind,
    required this.prefixStart,
  });

  final String label;
  final String insert;
  final String kind;
  final int prefixStart;
}

const _keywords = [
  'SELECT',
  'FROM',
  'WHERE',
  'AND',
  'OR',
  'NOT',
  'NULL',
  'IS',
  'IN',
  'LIKE',
  'BETWEEN',
  'INSERT',
  'INTO',
  'VALUES',
  'UPDATE',
  'SET',
  'DELETE',
  'CREATE',
  'TABLE',
  'VIEW',
  'INDEX',
  'DROP',
  'ALTER',
  'ADD',
  'COLUMN',
  'ORDER',
  'BY',
  'GROUP',
  'HAVING',
  'LIMIT',
  'OFFSET',
  'JOIN',
  'LEFT',
  'INNER',
  'CROSS',
  'ON',
  'AS',
  'DISTINCT',
  'PRIMARY',
  'KEY',
  'INTEGER',
  'TEXT',
  'REAL',
  'BLOB',
  'DEFAULT',
  'BEGIN',
  'COMMIT',
  'ROLLBACK',
  'PRAGMA',
  'WITH',
  'UNION',
  'ALL',
  'EXISTS',
  'CASE',
  'WHEN',
  'THEN',
  'ELSE',
  'END',
  'ASC',
  'DESC',
  'REPLACE',
  'RETURNING',
  'WITHOUT',
  'ROWID',
];

const _starters = [
  'SELECT',
  'INSERT',
  'UPDATE',
  'DELETE',
  'CREATE',
  'WITH',
  'PRAGMA',
  'DROP',
  'ALTER',
  'BEGIN',
];

const _tableContext = {'from', 'join', 'into', 'update'};
const _columnContext = {
  'select',
  'where',
  'and',
  'or',
  'set',
  'by',
  'having',
  'on',
  'distinct',
  'values',
};

/// Completions for [text] at [cursor], using the open schema.
List<SqlCompletion> sqlCompletions({
  required String text,
  required int cursor,
  required List<SchemaObject> objects,
  int limit = 12,
}) {
  final end = cursor < 0 ? text.length : cursor.clamp(0, text.length);
  if (_insideString(text, end)) return const [];
  var start = end;
  while (start > 0 && _ident(text.codeUnitAt(start - 1))) {
    start--;
  }
  final prefix = text.substring(start, end).toLowerCase();
  String? qualifier;
  if (start > 0 && text[start - 1] == '.') {
    var nameEnd = start - 1;
    var nameStart = nameEnd;
    while (nameStart > 0 && _ident(text.codeUnitAt(nameStart - 1))) {
      nameStart--;
    }
    qualifier = text.substring(nameStart, nameEnd);
  }
  final before = sqlWords(text.substring(
      0, qualifier == null ? start : start - 1 - (qualifier.length)));
  final previous = before.isEmpty ? '' : before.last;
  final earlier = before.length < 2 ? '' : before[before.length - 2];
  final relations = [
    for (final object in objects)
      if (object.type == 'table' || object.type == 'view') object,
  ];
  final mentioned = [
    for (final object in relations)
      if (before.contains(object.name.toLowerCase())) object,
  ];
  final wantsTable = _tableContext.contains(previous) ||
      (previous == 'table' && earlier != 'create') ||
      (previous == 'view' && earlier != 'create');
  final wantsColumn = qualifier != null ||
      _columnContext.contains(previous) ||
      (prefix.isNotEmpty &&
          !wantsTable &&
          (before.contains('select') ||
              before.contains('update') ||
              before.contains('where')));

  final items = <SqlCompletion>[];
  void add(String label, String insert, String kind) {
    if (items.length >= limit) return;
    if (items.any((item) => item.insert == insert && item.kind == kind)) {
      return;
    }
    items.add(SqlCompletion(
      label: label,
      insert: insert,
      kind: kind,
      prefixStart: start,
    ));
  }

  bool matches(String name) =>
      prefix.isEmpty || name.toLowerCase().startsWith(prefix);

  if (qualifier != null) {
    final owner = relations.cast<SchemaObject?>().firstWhere(
          (object) => object!.name.toLowerCase() == qualifier!.toLowerCase(),
          orElse: () => null,
        );
    if (owner != null) {
      for (final column in owner.columns) {
        if (matches(column.name)) add(column.name, column.name, 'column');
      }
    }
    return items;
  }

  if (previous == 'select' && prefix.isEmpty) {
    add('*', '*', 'keyword');
  }

  if (wantsTable || prefix.isEmpty && !wantsColumn) {
    for (final object in relations) {
      if (wantsTable && matches(object.name)) {
        add(object.name, object.name, object.type);
      }
    }
  }

  if (wantsColumn) {
    final scope = mentioned.isEmpty ? relations : mentioned;
    final names = <String, int>{};
    for (final object in scope) {
      for (final column in object.columns) {
        names[column.name] = (names[column.name] ?? 0) + 1;
      }
    }
    for (final object in scope) {
      for (final column in object.columns) {
        final shared = (names[column.name] ?? 0) > 1;
        final label = shared ? '${object.name}.${column.name}' : column.name;
        if (matches(column.name) || matches(label)) {
          add(label, label, 'column');
        }
      }
    }
  }

  final keywordSource =
      prefix.isEmpty && !wantsTable && !wantsColumn ? _starters : _keywords;
  if (prefix.isNotEmpty || (!wantsTable && !wantsColumn)) {
    for (final keyword in keywordSource) {
      if (matches(keyword)) add(keyword, keyword, 'keyword');
    }
  } else if (prefix.isNotEmpty) {
    for (final keyword in _keywords) {
      if (matches(keyword)) add(keyword, keyword, 'keyword');
    }
  }

  final definingName = earlier == 'create' &&
      (previous == 'table' || previous == 'view' || previous == 'index');
  if (prefix.isNotEmpty && !wantsTable && !definingName) {
    for (final object in relations) {
      if (matches(object.name)) add(object.name, object.name, object.type);
    }
  }
  return items;
}

bool _insideString(String text, int cursor) {
  String? quote;
  for (var i = 0; i < cursor && i < text.length; i++) {
    final char = text[i];
    if (quote != null) {
      if (char == quote) {
        final doubled = i + 1 < text.length && text[i + 1] == quote;
        if (doubled) {
          i++;
        } else {
          quote = null;
        }
      }
    } else if (char == "'" || char == '"') {
      quote = char;
    }
  }
  return quote != null;
}

bool _ident(int unit) {
  if (unit == 95) return true;
  if (unit >= 48 && unit <= 57) return true;
  if (unit >= 65 && unit <= 90) return true;
  if (unit >= 97 && unit <= 122) return true;
  return unit > 127;
}
