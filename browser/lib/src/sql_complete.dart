import 'session.dart';

/// One completion for the token at the cursor.
class SqlCompletion {
  const SqlCompletion({
    required this.label,
    required this.insert,
    required this.kind,
    required this.detail,
    required this.prefixStart,
  });

  final String label;
  final String insert;
  final String kind;
  final String detail;
  final int prefixStart;
}

const _starters = [
  'SELECT',
  'INSERT',
  'UPDATE',
  'DELETE',
  'CREATE',
  'DROP',
  'ALTER',
  'PRAGMA',
  'BEGIN',
  'WITH',
];

/// Completions that can follow the text already written. A prefix filters
/// that list. Nothing outside the current slot is offered.
List<SqlCompletion> sqlCompletions({
  required String text,
  required int cursor,
  required List<SchemaObject> objects,
  int limit = 8,
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
  final relations = [
    for (final object in objects)
      if (object.type == 'table' || object.type == 'view') object,
  ];
  final tokens = _tokens(
    text.substring(0, qualifier == null ? start : start - 1 - qualifier.length),
  );
  final names = tokens.map((token) => token.toLowerCase()).toList();
  final previous = names.isEmpty ? '' : names.last;
  final earlier = names.length < 2 ? '' : names[names.length - 2];
  final mentioned = [
    for (final object in relations)
      if (names.contains(object.name.toLowerCase())) object,
  ];

  final items = <SqlCompletion>[];
  void add(
    String label,
    String insert,
    String kind,
    String detail, {
    String? match,
  }) {
    if (items.length >= limit) return;
    final haystack = (match ?? label).toLowerCase();
    if (prefix.isNotEmpty && !haystack.startsWith(prefix)) return;
    if (items.any((item) => item.insert == insert)) return;
    items.add(SqlCompletion(
      label: label,
      insert: insert,
      kind: kind,
      detail: detail,
      prefixStart: start,
    ));
  }

  void addWords(List<String> words) {
    for (final word in words) {
      add(word, word, 'keyword', '');
    }
  }

  void addColumns(List<SchemaObject> scope) {
    final counts = <String, int>{};
    for (final object in scope) {
      for (final column in object.columns) {
        counts[column.name] = (counts[column.name] ?? 0) + 1;
      }
    }
    for (final object in scope) {
      for (final column in object.columns) {
        final shared = (counts[column.name] ?? 0) > 1;
        final label = shared ? '${object.name}.${column.name}' : column.name;
        add(label, label, 'column', column.type, match: column.name);
      }
    }
  }

  void addTables() {
    for (final object in relations) {
      add(object.name, object.name, object.type, object.type);
    }
  }

  if (qualifier != null) {
    for (final object in relations) {
      if (object.name.toLowerCase() == qualifier.toLowerCase()) {
        addColumns([object]);
      }
    }
    return items;
  }

  final beforeFrom = names.contains('select') && !names.contains('from');
  final columnScope = mentioned.isEmpty ? relations : mentioned;

  if (previous.isEmpty) {
    addWords(_starters);
    return items;
  }
  if (previous == ',') {
    if (beforeFrom) addColumns(columnScope);
    return items;
  }
  if (previous == 'select' || previous == 'distinct') {
    add('*', '*', 'keyword', '');
    if (previous == 'select') add('DISTINCT', 'DISTINCT', 'keyword', '');
    addColumns(columnScope);
    return items;
  }
  if (previous == '*' && beforeFrom) {
    addWords(['FROM', 'AS']);
    return items;
  }
  if (previous == 'from' ||
      previous == 'join' ||
      previous == 'into' ||
      previous == 'update' ||
      (previous == 'table' && earlier != 'create') ||
      (previous == 'view' && earlier != 'create') ||
      previous == 'references') {
    addTables();
    return items;
  }
  if (previous == 'where' ||
      previous == 'having' ||
      previous == 'on' ||
      previous == 'and' ||
      previous == 'or') {
    addColumns(columnScope);
    if (previous == 'where' || previous == 'having') {
      addWords(['NOT', 'EXISTS']);
    }
    return items;
  }
  if (previous == 'by') {
    addColumns(columnScope);
    addWords(['ASC', 'DESC']);
    return items;
  }
  if (previous == 'order' || previous == 'group') {
    addWords(['BY']);
    return items;
  }
  if (previous == 'limit') {
    addWords(['OFFSET']);
    return items;
  }
  if (previous == 'insert') {
    addWords(['INTO']);
    return items;
  }
  if (previous == 'delete') {
    addWords(['FROM']);
    return items;
  }
  if (previous == 'create') {
    addWords(['TABLE', 'VIEW', 'INDEX', 'TRIGGER']);
    return items;
  }
  if (previous == 'drop') {
    addWords(['TABLE', 'VIEW', 'INDEX', 'TRIGGER']);
    return items;
  }
  if (previous == 'alter') {
    addWords(['TABLE']);
    return items;
  }
  if (previous == 'add') {
    addWords(['COLUMN']);
    return items;
  }
  if (previous == 'set') {
    addColumns(columnScope);
    return items;
  }
  if (previous == 'as') {
    addWords(['FROM', 'WHERE', 'JOIN']);
    return items;
  }
  if (previous == 'left' || previous == 'inner' || previous == 'cross') {
    addWords(['JOIN']);
    return items;
  }
  if (previous == 'primary') {
    addWords(['KEY']);
    return items;
  }
  if (previous == 'not') {
    addWords(['NULL']);
    return items;
  }
  if (_isRelation(previous, relations)) {
    if (earlier == 'from' || earlier == 'join') {
      addWords(
          ['WHERE', 'JOIN', 'LEFT', 'INNER', 'ORDER', 'GROUP', 'LIMIT', 'AS']);
    } else if (earlier == 'update') {
      addWords(['SET']);
    } else if (earlier == 'into') {
      addWords(['VALUES']);
    } else if (earlier == 'table' && names.contains('alter')) {
      addWords(['ADD', 'RENAME', 'DROP']);
    }
    return items;
  }
  if (previous == '*' || _isColumn(previous, relations)) {
    if (beforeFrom) {
      addWords(['FROM', 'AS']);
    } else if (names.contains('where') ||
        names.contains('having') ||
        names.contains('on')) {
      addWords(['AND', 'OR', 'IS', 'LIKE', 'IN', 'BETWEEN', 'ORDER', 'LIMIT']);
    } else if (names.contains('set')) {
      addWords(['WHERE']);
    } else if (names.contains('by')) {
      addWords(['ASC', 'DESC', 'LIMIT']);
    }
    return items;
  }
  if (_ops.contains(previous)) return items;
  if (_number(previous)) {
    if (names.contains('where') ||
        names.contains('having') ||
        names.contains('on')) {
      addWords(['AND', 'OR', 'ORDER', 'LIMIT']);
    } else if (names.contains('limit')) {
      addWords(['OFFSET']);
    }
    return items;
  }
  if (previous == '(' && names.contains('create') && names.contains('table')) {
    addWords(['INTEGER', 'TEXT', 'REAL', 'BLOB', 'PRIMARY', 'NOT', 'UNIQUE']);
  }
  return items;
}

const _ops = {'=', '<', '>', '!', '+', '-', '/', '%'};

bool _number(String token) {
  if (token.isEmpty) return false;
  for (final unit in token.codeUnits) {
    if (unit < 48 || unit > 57) return false;
  }
  return true;
}

bool _isRelation(String name, List<SchemaObject> relations) {
  return relations.any((object) => object.name.toLowerCase() == name);
}

bool _isColumn(String name, List<SchemaObject> relations) {
  for (final object in relations) {
    for (final column in object.columns) {
      if (column.name.toLowerCase() == name) return true;
    }
  }
  return false;
}

/// Words and the symbols that change what can be typed next.
List<String> _tokens(String text) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var i = 0; i < text.length; i++) {
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
      continue;
    }
    if (char == "'" || char == '"') {
      _keep(tokens, buffer);
      quote = char;
      continue;
    }
    if (_ident(char.codeUnitAt(0))) {
      buffer.write(char);
      continue;
    }
    _keep(tokens, buffer);
    if (char == '*' ||
        char == ',' ||
        char == '(' ||
        char == ')' ||
        _ops.contains(char)) {
      tokens.add(char);
    }
  }
  _keep(tokens, buffer);
  return tokens;
}

void _keep(List<String> tokens, StringBuffer buffer) {
  if (buffer.isEmpty) return;
  tokens.add(buffer.toString());
  buffer.clear();
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
