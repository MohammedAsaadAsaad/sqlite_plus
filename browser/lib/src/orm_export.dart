import 'format.dart';
import 'schema_sql.dart';
import 'session.dart';

/// One step for saving the classes and generating the whole package.
class OrmModelStep {
  const OrmModelStep(this.title, this.detail, {this.command});

  final String title;
  final String detail;

  /// A command or snippet shown on its own line.
  final String? command;
}

/// Steps shown from How to use and repeated at the top of the file.
const ormModelSteps = [
  OrmModelStep(
    'Put the classes in lib/',
    'Save this file in the Dart package, for example as lib/models.dart. '
        'Keep every class from this file in that one library. A reference '
        'names a class in the same library.',
  ),
  OrmModelStep(
    'Add the packages',
    'Add sqlite_plus_orm to dependencies and sqlite_plus_generator to '
        'dev_dependencies.',
  ),
  OrmModelStep(
    'Generate for the whole project',
    'From the package root, run this command. It reads every public '
        '@DbEntity class under lib/ and writes the parts. The part directive '
        'is added for you.',
    command: 'dart run sqlite_plus_generator',
  ),
  OrmModelStep(
    'Open the package model',
    'Import lib/sqlite_plus_migrations.g.dart. Hide generatedModel on each '
        'model import, and use the package model for the context.',
    command: 'final context = DbContext(connection, generatedModel);\n'
        'await context.migrations.ensureCreated();',
  ),
];

/// Short notes repeated under the steps. They are not classes.
const ormModelHints = [
  'A single integer primary key is BigInt? with @DbKey(generated: true).',
  '@DbColumn(name:) keeps the SQL column name. One @DbReference is one column.',
];

/// A library of `@DbEntity` classes for the open tables.
///
/// The generator reads this file. `@DbEntity(table:)` keeps the SQL table
/// name, and `@DbColumn(name:)` keeps a SQL column whose Dart name differs.
/// A single integer primary key is `BigInt?` so the engine can assign it.
/// One `@DbReference` is one column. A foreign key of several columns stays
/// in a comment.
String ormModels(List<SchemaObject> objects) {
  final tables = [
    for (final object in objects)
      if (object.type == 'table' && !_internal(object.name)) object,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final planned = <_Table>[];
  final usedClasses = <String>{};
  final hiddenShadows = <String>{};
  for (final table in tables) {
    final virtual = _virtual(table.sql);
    final shadow = _shadowOf(table, tables);
    if (shadow != null) {
      hiddenShadows.add(shadow);
      continue;
    }
    final reason = virtual
        ? '${table.name} is a virtual table. Write its fts5, rtree, or vec0 class by hand.'
        : table.columns.isEmpty
            ? '${table.name} has no columns.'
            : _keyPositions(table).isEmpty
                ? '${table.name} has no primary key, so the generator cannot own it.'
                : null;
    planned.add(
      _Table(
        source: table,
        className: _unique(_typeName(table.name), usedClasses),
        skip: reason,
        withoutRowid: _withoutRowid(table.sql),
      ),
    );
  }
  final byTable = {
    for (final table in planned) table.source.name.toLowerCase(): table,
  };
  for (final table in planned) {
    if (table.skip != null) continue;
    _fields(table, planned, byTable, objects);
  }
  final needsBytes = planned.any(
    (table) =>
        table.fields.any((field) => field.dartType.contains('Uint8List')),
  );
  final buffer = StringBuffer();
  if (needsBytes) buffer.writeln("import 'dart:typed_data';");
  buffer
    ..writeln("import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';")
    ..writeln();
  buffer.writeln('// How to use');
  for (var i = 0; i < ormModelSteps.length; i++) {
    final step = ormModelSteps[i];
    buffer.writeln('// ${i + 1}. ${step.title}');
    for (final line in step.detail.split('\n')) {
      buffer.writeln('//    $line');
    }
    final command = step.command;
    if (command != null) {
      for (final line in command.split('\n')) {
        buffer.writeln('//    $line');
      }
    }
  }
  for (final hint in ormModelHints) {
    buffer.writeln('// $hint');
  }
  final notes = <String>[
    for (final table in planned)
      if (table.skip != null) table.skip!,
    for (final name in hiddenShadows) 'Internal tables of $name were left out.',
    for (final object in objects)
      if (object.type == 'view' && !_internal(object.name))
        'View ${object.name} is not a generated class.',
    for (final object in objects)
      if (object.type == 'trigger' && !_internal(object.name))
        'Trigger ${object.name} is not a generated class.',
  ];
  for (final note in notes) {
    buffer.writeln('// $note');
  }
  if (planned.every((table) => table.skip != null)) {
    buffer
      ..writeln()
      ..writeln('// This database has no table the generator can own.');
    return buffer.toString();
  }
  for (final table in planned) {
    if (table.skip != null) continue;
    buffer
      ..writeln()
      ..writeln(_class(table, objects));
  }
  return buffer.toString();
}

/// One `@DbEntity` class cut out of [ormModels] for its own card.
class ModelClassBlock {
  const ModelClassBlock({
    required this.name,
    required this.table,
    required this.source,
  });

  final String name;
  final String table;
  final String source;
}

/// Imports, leftover notes, and the classes in an exported library.
class ModelLibraryParts {
  const ModelLibraryParts({
    required this.imports,
    required this.notes,
    required this.classes,
  });

  final List<String> imports;
  final List<String> notes;
  final List<ModelClassBlock> classes;
}

/// Splits an [ormModels] library into the pieces the dialog shows.
ModelLibraryParts splitModelLibrary(String source) {
  final marker = RegExp(r'^@DbEntity', multiLine: true);
  final starts = [for (final match in marker.allMatches(source)) match.start];
  final head = starts.isEmpty ? source : source.substring(0, starts.first);
  final imports = <String>[];
  final notes = <String>[];
  for (final raw in head.split('\n')) {
    final line = raw.trimRight();
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('import ')) {
      imports.add(trimmed);
      continue;
    }
    if (!trimmed.startsWith('//')) continue;
    final text = trimmed.substring(2).trim();
    if (text.isEmpty || text == 'How to use') continue;
    if (RegExp(r'^\d+\.\s').hasMatch(text)) continue;
    if (trimmed.startsWith('//    ')) continue;
    if (ormModelHints.contains(text)) continue;
    notes.add(text);
  }
  final classes = <ModelClassBlock>[];
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : source.length;
    final chunk = source.substring(starts[i], end).trim();
    final name =
        RegExp(r'\bclass\s+([A-Za-z_]\w*)').firstMatch(chunk)?.group(1) ??
            'Class';
    final tableMatch = RegExp(r"table:\s*'((?:\\'|[^'])*)'").firstMatch(chunk);
    final table = (tableMatch?.group(1) ?? name).replaceAll(r"\'", "'");
    classes.add(ModelClassBlock(name: name, table: table, source: chunk));
  }
  return ModelLibraryParts(imports: imports, notes: notes, classes: classes);
}

bool _internal(String name) => name.toLowerCase().startsWith('sqlite_');

String? _shadowOf(SchemaObject table, List<SchemaObject> tables) {
  final lower = table.name.toLowerCase();
  for (final other in tables) {
    if (identical(other, table) || !_virtual(other.sql)) continue;
    final prefix = '${other.name.toLowerCase()}_';
    if (lower.startsWith(prefix)) return other.name;
  }
  final sql = table.sql;
  if (sql == null || sql.trim().isEmpty) return table.name;
  return null;
}

bool _virtual(String? sql) {
  if (sql == null) return false;
  return RegExp(r'create\s+virtual\s+table', caseSensitive: false)
      .hasMatch(sql);
}

bool _withoutRowid(String? sql) {
  if (sql == null) return false;
  return RegExp(r'\bwithout\s+rowid\b', caseSensitive: false).hasMatch(sql);
}

void _fields(
  _Table table,
  List<_Table> planned,
  Map<String, _Table> byTable,
  List<SchemaObject> catalog,
) {
  final used = <String>{};
  final keys = _keyPositions(table.source);
  final generated = keys.length == 1 &&
      !table.withoutRowid &&
      cellKind(keys.keys.single.type) == CellKind.integer;
  for (final column in table.source.columns) {
    final position = _position(column, table.source);
    final key = position > 0;
    final nullable = !column.notNull || (key && generated);
    final kind = cellKind(column.type);
    final dartType = _dartType(column, kind, nullable);
    table.fields.add(
      _Field(
        column: column,
        name: _unique(_fieldName(column.name), used),
        dartType: dartType,
        nullable: nullable,
        generated: key && generated,
        keyOrder: key ? position - 1 : null,
        unique:
            !key && columnDeclaredUnique(table.source, column.name, catalog),
        defaultSql: _defaultSql(column.defaultValue),
      ),
    );
  }
  final groups = <int, List<ForeignKeyInfo>>{};
  for (final key in table.source.foreignKeys) {
    groups.putIfAbsent(key.constraint, () => []).add(key);
  }
  for (final group in groups.values) {
    group.sort((a, b) => a.position.compareTo(b.position));
    if (group.length != 1) {
      for (final key in group) {
        final field = table.fields
            .where((item) => item.column.name == key.from)
            .firstOrNull;
        field?.note =
            '${key.from} is part of a foreign key of several columns, so it has no @DbReference.';
      }
      continue;
    }
    final key = group.single;
    final field =
        table.fields.where((item) => item.column.name == key.from).firstOrNull;
    if (field == null) continue;
    final parent = byTable[key.table.toLowerCase()];
    if (parent == null || parent.skip != null) {
      field.note = '${key.from} references ${key.table}, which is not a model.';
      continue;
    }
    final parentKeys = parent.fields.where((item) => item.keyOrder != null);
    final targetName = key.to;
    final target = targetName == null || targetName.isEmpty
        ? parentKeys.length == 1
            ? parentKeys.single
            : null
        : parent.fields
            .where((item) =>
                item.column.name.toLowerCase() == targetName.toLowerCase())
            .firstOrNull;
    final soleKey = parentKeys.length == 1 && target == parentKeys.single;
    final targetUnique = target != null &&
        columnDeclaredUnique(parent.source, target.column.name, catalog);
    if (target == null || (!soleKey && !targetUnique)) {
      field.note =
          '${key.from} references ${key.table}.${targetName ?? ''}, which is not a single unique column.';
      continue;
    }
    if (field.dartType.replaceAll('?', '') !=
        target.dartType.replaceAll('?', '')) {
      field.note =
          '${key.from} and ${parent.className}.${target.name} use different Dart types.';
      continue;
    }
    final action = _deleteAction(key.onDelete);
    if (action == 'setNull' && !field.nullable) {
      field.note =
          '${key.from} uses ON DELETE SET NULL, and the column is NOT NULL.';
      continue;
    }
    if (action == 'setDefault' && !field.nullable && field.defaultSql == null) {
      field.note =
          '${key.from} uses ON DELETE SET DEFAULT, and the column has no default.';
      continue;
    }
    field.reference = _Reference(
      parent.className,
      column: soleKey ? null : target.name,
      action: action,
    );
    if (key.onUpdate.isNotEmpty && key.onUpdate.toUpperCase() != 'NO ACTION') {
      field.note =
          'ON UPDATE ${key.onUpdate} is not an argument of @DbReference.';
    }
  }
}

Map<ColumnInfo, int> _keyPositions(SchemaObject table) {
  final marked = [
    for (final column in table.columns)
      if (column.primaryKey || column.keyPosition > 0) column,
  ];
  final positions = <ColumnInfo, int>{};
  for (final column in marked) {
    if (column.keyPosition > 0) {
      positions[column] = column.keyPosition;
    }
  }
  if (positions.length == marked.length && positions.isNotEmpty) {
    return positions;
  }
  if (marked.length == 1) return {marked.single: 1};
  for (var i = 0; i < marked.length; i++) {
    positions.putIfAbsent(marked[i], () => i + 1);
  }
  return positions;
}

int _position(ColumnInfo column, SchemaObject table) =>
    _keyPositions(table)[column] ?? 0;

String _dartType(ColumnInfo column, CellKind kind, bool nullable) {
  final declared = column.type.trim();
  if (declared.toUpperCase().contains('BLOB')) {
    return nullable ? 'Uint8List?' : 'Uint8List';
  }
  final base = declared.isEmpty
      ? 'String'
      : switch (kind) {
          CellKind.integer => 'BigInt',
          CellKind.real => 'double',
          CellKind.boolean => 'bool',
          CellKind.text ||
          CellKind.date ||
          CellKind.time ||
          CellKind.dateTime =>
            'String',
        };
  return nullable ? '$base?' : base;
}

String? _defaultSql(String? value) {
  if (value == null) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  return text;
}

String? _deleteAction(String action) {
  switch (action.toUpperCase().replaceAll(' ', '')) {
    case 'CASCADE':
      return 'cascade';
    case 'RESTRICT':
      return 'restrict';
    case 'SETNULL':
      return 'setNull';
    case 'SETDEFAULT':
      return 'setDefault';
    default:
      return null;
  }
}

String _class(_Table table, List<SchemaObject> catalog) {
  final buffer = StringBuffer()
    ..writeln("@DbEntity(table: '${_dartString(table.source.name)}')")
    ..writeln('class ${table.className} {')
    ..writeln('  ${table.className}({');
  for (final field in table.fields) {
    final prefix =
        field.nullable ? 'this.${field.name}' : 'required this.${field.name}';
    buffer.writeln('    $prefix,');
  }
  buffer.writeln('  });');
  for (final field in table.fields) {
    buffer.writeln();
    if (field.note != null) buffer.writeln('  // ${field.note}');
    if (field.keyOrder != null) {
      if (field.generated) {
        buffer.writeln('  @DbKey(generated: true)');
      } else if (table.fields.where((item) => item.keyOrder != null).length ==
          1) {
        buffer.writeln('  @DbKey()');
      } else {
        buffer.writeln('  @DbKey(order: ${field.keyOrder})');
      }
    }
    final reference = field.reference;
    if (reference != null) {
      final arguments = <String>[reference.className];
      if (reference.column != null) {
        arguments.add("column: '${_dartString(reference.column!)}'");
      }
      if (reference.action != null) {
        arguments.add('onDelete: ForeignKeyAction.${reference.action}');
      }
      buffer.writeln('  @DbReference(${arguments.join(', ')})');
    }
    final column = <String>[];
    if (field.name != field.column.name) {
      column.add("name: '${_dartString(field.column.name)}'");
    }
    if (field.defaultSql != null) {
      column.add("defaultSql: '${_dartString(field.defaultSql!)}'");
    }
    if (field.unique) column.add('unique: true');
    if (column.isNotEmpty) {
      buffer.writeln('  @DbColumn(${column.join(', ')})');
    }
    if (field.column.type.trim().isEmpty) {
      buffer.writeln('  // ${field.column.name} has no declared type.');
    }
    buffer.writeln('  final ${field.dartType} ${field.name};');
  }
  final wide = [
    for (final object in catalog)
      if (object.type == 'index' &&
          object.unique &&
          object.indexColumns.length > 1 &&
          object.table.toLowerCase() == table.source.name.toLowerCase() &&
          !_internal(object.name))
        object,
  ];
  for (final index in wide) {
    buffer.writeln(
      '  // Unique index ${index.name} (${index.indexColumns.join(', ')}) covers several columns.',
    );
  }
  buffer.writeln('}');
  return buffer.toString().trimRight();
}

String _typeName(String name) {
  final words = _words(name);
  if (words.isEmpty) return 'Table';
  final text = words.map(_capitalize).join();
  return _safe(text, kind: _NameKind.type);
}

String _fieldName(String name) {
  final words = _words(name);
  if (words.isEmpty) return 'value';
  final first = words.first.toLowerCase();
  final rest = words.skip(1).map(_capitalize).join();
  return _safe('$first$rest', kind: _NameKind.field);
}

List<String> _words(String name) {
  final spaced = name.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match[1]} ${match[2]}',
  );
  return [
    for (final word in spaced.split(RegExp(r'[^A-Za-z0-9]+')))
      if (word.isNotEmpty) word,
  ];
}

String _capitalize(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

String _safe(String name, {required _NameKind kind}) {
  var text = name;
  if (text.isEmpty || RegExp(r'^[0-9]').hasMatch(text)) text = 'n$text';
  if (_reserved.contains(text)) {
    text = kind == _NameKind.type ? '${text}Table' : '${text}Value';
  }
  return text;
}

String _unique(String name, Set<String> used) {
  var text = name;
  var suffix = 2;
  while (!used.add(text)) {
    text = '$name$suffix';
    suffix++;
  }
  return text;
}

String _dartString(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', '');

enum _NameKind { type, field }

const _reserved = {
  'all',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'deferred',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'get',
  'hashCode',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'noSuchMethod',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'runtimeType',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'toString',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

class _Table {
  _Table({
    required this.source,
    required this.className,
    required this.withoutRowid,
    this.skip,
  });

  final SchemaObject source;
  final String className;
  final bool withoutRowid;
  final String? skip;
  final List<_Field> fields = [];
}

class _Field {
  _Field({
    required this.column,
    required this.name,
    required this.dartType,
    required this.nullable,
    required this.generated,
    required this.keyOrder,
    required this.unique,
    required this.defaultSql,
  });

  final ColumnInfo column;
  final String name;
  final String dartType;
  final bool nullable;
  final bool generated;
  final int? keyOrder;
  final bool unique;
  final String? defaultSql;
  _Reference? reference;
  String? note;
}

class _Reference {
  _Reference(this.className, {this.column, this.action});

  final String className;
  final String? column;
  final String? action;
}
