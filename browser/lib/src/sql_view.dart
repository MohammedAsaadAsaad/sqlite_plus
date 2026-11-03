import 'package:flutter/material.dart';

const _keywords = {
  'abort',
  'action',
  'add',
  'all',
  'and',
  'as',
  'asc',
  'autoincrement',
  'begin',
  'between',
  'by',
  'cascade',
  'case',
  'check',
  'collate',
  'column',
  'conflict',
  'constraint',
  'create',
  'default',
  'deferrable',
  'deferred',
  'delete',
  'desc',
  'distinct',
  'drop',
  'else',
  'end',
  'exists',
  'fail',
  'foreign',
  'from',
  'group',
  'having',
  'if',
  'ignore',
  'immediate',
  'in',
  'index',
  'initially',
  'inner',
  'insert',
  'into',
  'is',
  'join',
  'key',
  'left',
  'like',
  'limit',
  'match',
  'not',
  'null',
  'offset',
  'on',
  'or',
  'order',
  'outer',
  'primary',
  'references',
  'replace',
  'restrict',
  'rollback',
  'rowid',
  'select',
  'set',
  'table',
  'temp',
  'temporary',
  'then',
  'trigger',
  'union',
  'unique',
  'update',
  'using',
  'values',
  'view',
  'virtual',
  'when',
  'where',
  'with',
  'without',
};

const _types = {
  'blob',
  'boolean',
  'char',
  'clob',
  'date',
  'datetime',
  'double',
  'float',
  'int',
  'integer',
  'numeric',
  'nvarchar',
  'real',
  'text',
  'varchar',
};

/// One column or clause per line, with `PRIMARY KEY` kept together.
String formatSql(String sql) {
  final compact = _compact(sql);
  if (compact.isEmpty) return compact;
  final created = _formatCreate(compact);
  if (created != null) return created;
  return _breakClauses(compact);
}

String _compact(String sql) {
  final buffer = StringBuffer();
  String? quote;
  var pendingSpace = false;
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote != null) {
      buffer.write(char);
      if (char == quote) {
        final doubled = i + 1 < sql.length && sql[i + 1] == quote;
        if (doubled) {
          buffer.write(sql[i + 1]);
          i++;
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      if (pendingSpace && buffer.isNotEmpty) buffer.write(' ');
      pendingSpace = false;
      quote = char;
      buffer.write(char);
      continue;
    }
    if (char.trim().isEmpty) {
      pendingSpace = buffer.isNotEmpty;
      continue;
    }
    if (pendingSpace) buffer.write(' ');
    pendingSpace = false;
    buffer.write(char);
  }
  return buffer.toString().trim();
}

String? _formatCreate(String sql) {
  final upper = sql.toUpperCase();
  if (!upper.startsWith('CREATE ')) return null;
  final table = upper.contains(' TABLE ');
  final index = upper.contains(' INDEX ');
  if (!table && !index) return _breakClauses(sql);
  final open = sql.indexOf('(');
  if (open < 0) return _breakClauses(sql);
  final close = _matchingParen(sql, open);
  if (close < 0) return sql;
  final head = sql.substring(0, open).trim();
  final items = _splitTop(sql.substring(open + 1, close))
      .map((item) => item.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((item) => item.isNotEmpty)
      .toList();
  if (items.isEmpty) return _breakClauses(sql);
  final tail = sql.substring(close + 1).trim();
  final buffer = StringBuffer()..writeln('$head (');
  for (var i = 0; i < items.length; i++) {
    final comma = i == items.length - 1 ? '' : ',';
    buffer.writeln('  ${items[i]}$comma');
  }
  buffer.write(')');
  if (tail.isNotEmpty) buffer.write('\n$tail');
  return buffer.toString();
}

String _breakClauses(String sql) {
  const breaks = [
    'SELECT ',
    'FROM ',
    'WHERE ',
    'GROUP BY ',
    'ORDER BY ',
    'HAVING ',
    'LIMIT ',
    'UNION ALL ',
    'UNION ',
    'VALUES ',
    'SET ',
    'LEFT JOIN ',
    'INNER JOIN ',
    'JOIN ',
    'BEGIN ',
    'END',
  ];
  final buffer = StringBuffer();
  String? quote;
  var depth = 0;
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote != null) {
      buffer.write(char);
      if (char == quote) {
        final doubled = i + 1 < sql.length && sql[i + 1] == quote;
        if (doubled) {
          buffer.write(sql[i + 1]);
          i++;
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
    if (char == '(') depth++;
    if (char == ')' && depth > 0) depth--;
    if (depth == 0 && i > 0) {
      final rest = sql.substring(i).toUpperCase();
      final matched = breaks.cast<String?>().firstWhere(
            (word) => rest.startsWith(word!) && _boundary(sql, i),
            orElse: () => null,
          );
      if (matched != null) {
        buffer.write('\n');
      }
    }
    buffer.write(char);
  }
  return buffer
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

bool _boundary(String sql, int index) {
  if (index == 0) return true;
  final unit = sql.codeUnitAt(index - 1);
  if (unit == 95) return false;
  if (unit >= 48 && unit <= 57) return false;
  if (unit >= 65 && unit <= 90) return false;
  if (unit >= 97 && unit <= 122) return false;
  return unit <= 127;
}

int _matchingParen(String sql, int open) {
  var depth = 0;
  String? quote;
  for (var i = open; i < sql.length; i++) {
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
    if (char == '(') depth++;
    if (char == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

List<String> _splitTop(String input) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  String? quote;
  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (quote != null) {
      buffer.write(char);
      if (char == quote) {
        final doubled = i + 1 < input.length && input[i + 1] == quote;
        if (doubled) {
          buffer.write(input[i + 1]);
          i++;
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
    if (char == '(') depth++;
    if (char == ')' && depth > 0) depth--;
    if (char == ',' && depth == 0) {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty) parts.add(buffer.toString());
  return parts;
}

/// A dark, monospaced view of one SQL statement.
class SqlCodeView extends StatelessWidget {
  const SqlCodeView({super.key, required this.source});

  final String source;

  static const _lineHeight = 22.0;
  static const _font = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: 13,
    height: 22 / 13,
    color: Color(0xFFE7F3EE),
  );

  @override
  Widget build(BuildContext context) {
    final text = source.isEmpty ? '' : source;
    final lines = text.isEmpty ? const [''] : text.split('\n');
    final height = 24 + lines.length * _lineHeight;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF17241F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2C3C36)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: height > 360 ? 360 : height,
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < lines.length; i++)
                          SizedBox(
                            height: _lineHeight,
                            width: 28,
                            child: Text(
                              '${i + 1}',
                              textAlign: TextAlign.right,
                              style: _font.copyWith(
                                color: const Color(0xFF6E847C),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    SelectableText.rich(
                      TextSpan(style: _font, children: _spans(text)),
                      key: const Key('sql-code'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

List<InlineSpan> _spans(String source) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();
  String? quote;
  var ident = false;

  void flush(Color color) {
    if (buffer.isEmpty) return;
    spans
        .add(TextSpan(text: buffer.toString(), style: TextStyle(color: color)));
    buffer.clear();
  }

  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (quote != null) {
      buffer.write(char);
      if (char == quote) {
        final doubled = i + 1 < source.length && source[i + 1] == quote;
        if (doubled) {
          buffer.write(source[i + 1]);
          i++;
        } else {
          flush(const Color(0xFFF3C7A0));
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      flush(const Color(0xFFE7F3EE));
      quote = char;
      buffer.write(char);
      continue;
    }
    final word = _wordChar(char);
    if (word != ident && buffer.isNotEmpty && quote == null) {
      flush(_color(buffer.toString(), ident));
    }
    ident = word;
    if (!word && char != '\n' && !_symbol(char)) {
      if (buffer.isNotEmpty) flush(_color(buffer.toString(), ident));
      spans.add(TextSpan(text: char));
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty) {
    flush(quote != null
        ? const Color(0xFFF3C7A0)
        : _color(buffer.toString(), ident));
  }
  return spans;
}

bool _wordChar(String char) {
  if (char.isEmpty) return false;
  final unit = char.codeUnitAt(0);
  if (unit == 95) return true;
  if (unit >= 48 && unit <= 57) return true;
  if (unit >= 65 && unit <= 90) return true;
  if (unit >= 97 && unit <= 122) return true;
  return unit > 127;
}

bool _symbol(String char) => '(),.;'.contains(char);

Color _color(String token, bool word) {
  if (!word) return const Color(0xFF93A89F);
  if (int.tryParse(token) != null) return const Color(0xFFC9E4FF);
  final lower = token.toLowerCase();
  if (_keywords.contains(lower)) return const Color(0xFF7DDBB6);
  if (_types.contains(lower)) return const Color(0xFFF0D78C);
  return const Color(0xFFE7F3EE);
}
