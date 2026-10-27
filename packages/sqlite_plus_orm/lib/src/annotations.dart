part of '../sqlite_plus_orm.dart';

class DbEntity {
  const DbEntity({this.table, this.module});
  final String? table;

  /// `fts5` or `rtree`. Omitted models stay ordinary tables.
  final String? module;
}

/// Marks one TEXT column for a generated JSON path helper.
class DbJson {
  const DbJson();
}

class DbColumn {
  const DbColumn({this.name, this.defaultSql, this.unique = false});
  final String? name;
  final String? defaultSql;
  final bool unique;
}

class DbIgnore {
  const DbIgnore();
}

class DbKey {
  const DbKey({this.order = 0, this.generated = false});
  final int order;
  final bool generated;
}

class DbVersion {
  const DbVersion();
}

class DbReference {
  const DbReference(this.target,
      {this.column, this.onDelete = ForeignKeyAction.noAction});
  final Type target;

  /// Target Dart property name; omitted for a single primary key.
  final String? column;
  final ForeignKeyAction onDelete;
}
