import 'dart:typed_data';

import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

class _Entity {
  _Entity({this.id, this.name = 'name', this.revision = 0, this.bytes});
  BigInt? id;
  String name;
  int revision;
  Uint8List? bytes;
}

Column<_Entity, BigInt?> _id(
        {String? name, int? order = 0, bool generated = true}) =>
    Column(
        property: 'id',
        name: name,
        codec: Codecs.nullable(Codecs.bigInt),
        read: (value) => value.id,
        write: (value, id) => value.id = id,
        keyOrder: order,
        generated: generated);
Column<_Entity, BigInt> _assignedId({int order = 0, bool version = false}) =>
    Column(
        property: 'id',
        codec: Codecs.bigInt,
        read: (value) => value.id!,
        keyOrder: order,
        version: version);
Column<_Entity, String> _name(
        {String? name,
        int? order,
        bool unique = false,
        bool version = false}) =>
    Column(
        property: 'name',
        name: name,
        codec: Codecs.text,
        read: (value) => value.name,
        keyOrder: order,
        unique: unique,
        version: version);
EntityType<_Entity> _type(List<Column<_Entity, dynamic>> columns,
        {String table = 'entities',
        List<OrmIndex<_Entity>> indexes = const []}) =>
    EntityType(
        tableName: table,
        columns: columns,
        indexes: indexes,
        create: (_) => _Entity());

class _BadCodec extends ValueCodec<String> {
  const _BadCodec({this.type = 'TEXT'});
  final String type;
  @override
  String get sqlType => type;
  @override
  Object? encode(String value) => Object();
  @override
  String decode(Object? value) => throw StateError('private cause');
}

void main() {
  final mappingError = throwsA(isA<OrmMappingException>());
  test('identifiers quote Unicode, SQL words, whitespace and embedded quotes',
      () {
    expect(quoteIdentifier('select'), '"select"');
    expect(quoteIdentifier(' 名 " x '), '" 名 "" x "');
    final id = _id(name: 'primary " key');
    final name = _name(name: 'مرحبا');
    final type = _type([id, name], table: ' group "名');
    expect(type.tableName, ' group "名');
    expect(type.dartType, _Entity);
    expect(type.generatedKey, same(id));
    expect(type.encode(_Entity(name: 'Ada')),
        {'primary " key': null, 'مرحبا': 'Ada'});
    expect(() => quoteIdentifier(''), mappingError);
    expect(() => quoteIdentifier('a\u0000b'), mappingError);
  });

  test('column schema metadata validates names, key and declared codec type',
      () {
    for (final name in ['', 'a\u0000b']) {
      expect(() => _id(name: name), mappingError);
      expect(() => _type([_id()], table: name), mappingError);
    }
    expect(() => _type([_id()], table: 'SQLITE_internal'), mappingError);
    expect(() => _id(order: -1), mappingError);
    expect(() => _id(order: null), mappingError);
    expect(
        () => Column<_Entity, String>(
            property: 'x',
            codec: const _BadCodec(type: 'NUMERIC'),
            read: (_) => ''),
        mappingError);
    for (final value in ['', ' ', '0\u0000']) {
      expect(
          () => Column<_Entity, String>(
              property: 'x',
              codec: Codecs.text,
              read: (_) => '',
              defaultSql: value),
          mappingError);
    }
  });

  test('column and property duplicates use database ASCII naming rules', () {
    expect(() => _type([_id(name: 'ID'), _name(name: 'id')]), mappingError);
    expect(() => _type([_id(), _id(name: 'other')]), mappingError);
    final first = _name(name: 'Å');
    final second = Column<_Entity, String>(
        property: 'other',
        name: 'å',
        codec: Codecs.text,
        read: (entity) => entity.name);
    expect(_type([_id(), first, second]).columns, hasLength(3));
  });

  test('entity needs unique ordered primary-key metadata', () {
    expect(() => _type([]), mappingError);
    expect(() => _type([_name()]), mappingError);
    expect(() => _type([_assignedId(), _name(order: 0)]), mappingError);
    final id = _assignedId(order: 8), name = _name(order: 2);
    final type = _type([id, name]);
    expect(type.keys, [name, id]);
    expect(type.generatedKey, isNull);
    final assignedNullable = _id(generated: false);
    expect(_type([assignedNullable]).keys, [assignedNullable]);
    final assignedText = Column<_Entity, String?>(
        property: 'id',
        codec: Codecs.nullable(Codecs.text),
        read: (_) => 'assigned',
        keyOrder: 0);
    expect(_type([assignedText]).generatedKey, isNull);
  });

  test('generated keys are one nullable built-in integer field', () {
    expect(() => _type([_id(), _name(order: 1)]), mappingError);
    expect(
        () => _type([
              Column<_Entity, BigInt>(
                  property: 'id',
                  codec: Codecs.bigInt,
                  read: (_) => BigInt.one,
                  keyOrder: 0,
                  generated: true)
            ]),
        mappingError);
    expect(
        () => _type([
              Column<_Entity, String?>(
                  property: 'id',
                  codec: Codecs.nullable(Codecs.text),
                  read: (_) => null,
                  keyOrder: 0,
                  generated: true)
            ]),
        mappingError);
    final small = Column<_Entity, int?>(
        property: 'id',
        codec: Codecs.nullable(Codecs.integer),
        read: (_) => null,
        keyOrder: 0,
        generated: true);
    expect(_type([small]).generatedKey, same(small));
    final second = Column<_Entity, BigInt?>(
        property: 'second',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (_) => null,
        keyOrder: 1,
        generated: true);
    expect(() => _type([_id(), second]), mappingError);
  });

  test('versions are single nonnullable integer non-key fields', () {
    final revision = Column<_Entity, int>(
        property: 'revision',
        codec: Codecs.integer,
        read: (entity) => entity.revision,
        version: true);
    expect(_type([_id(), revision]).versionColumn, same(revision));
    expect(() => _type([_id(), _name(version: true)]), mappingError);
    expect(() => _type([_assignedId(version: true)]), mappingError);
    expect(
        () => _type([
              _id(),
              Column<_Entity, int?>(
                  property: 'revision',
                  codec: Codecs.nullable(Codecs.integer),
                  read: (_) => null,
                  version: true)
            ]),
        mappingError);
    expect(
        () => _type([
              _id(),
              revision,
              Column<_Entity, BigInt>(
                  property: 'other',
                  codec: Codecs.bigInt,
                  read: (_) => BigInt.zero,
                  version: true)
            ]),
        mappingError);
  });

  test('indexes require distinct entity-owned columns and unique schema names',
      () {
    final id = _id(), name = _name();
    expect(() => OrmIndex<_Entity>(name: 'empty', columns: []), mappingError);
    expect(() => OrmIndex<_Entity>(name: 'sqlite_reserved', columns: [name]),
        mappingError);
    expect(() => OrmIndex<_Entity>(name: 'dupe', columns: [name, name]),
        mappingError);
    expect(
        () => _type([
              id,
              name
            ], indexes: [
              OrmIndex(name: 'alien', columns: [_name()])
            ]),
        mappingError);
    expect(
        () => _type([
              id,
              name
            ], indexes: [
              OrmIndex(name: 'idx', columns: [name]),
              OrmIndex(name: 'IDX', columns: [id]),
            ]),
        mappingError);
    final type = _type([
      id,
      name
    ], indexes: [
      OrmIndex(name: 'people_name', columns: [name])
    ]);
    expect(
        () => DbModel([
              type,
              _type([_id()], table: 'PEOPLE_NAME')
            ]),
        mappingError);
    expect(
        () => DbModel([
              type,
              _type([_id()], table: 'ENTITIES')
            ]),
        mappingError);
  });

  test('metadata lists are defensive and immutable', () {
    final id = _id(), name = _name();
    final indexColumns = <Column<_Entity, dynamic>>[name];
    final index = OrmIndex(name: 'idx', columns: indexColumns);
    final indexes = [index];
    final columns = <Column<_Entity, dynamic>>[id, name];
    final type = _type(columns, indexes: indexes);
    final entities = <EntityType<dynamic>>[type];
    final model = DbModel(entities);
    columns.clear();
    indexes.clear();
    indexColumns.clear();
    entities.clear();
    expect(type.columns, [id, name]);
    expect(type.indexes, [index]);
    expect(index.columns, [name]);
    expect(model.entities, [type]);
    expect(() => type.columns.clear(), throwsUnsupportedError);
    expect(() => type.keys.clear(), throwsUnsupportedError);
    expect(() => type.indexes.clear(), throwsUnsupportedError);
    expect(() => index.columns.clear(), throwsUnsupportedError);
    expect(() => model.entities.clear(), throwsUnsupportedError);
  });

  test('entity encoding captures typed values and copies mutable blob state',
      () {
    final revision = Column<_Entity, int>(
        property: 'revision',
        codec: Codecs.integer,
        read: (entity) => entity.revision);
    final blob = Column<_Entity, Uint8List?>(
        property: 'bytes',
        codec: Codecs.nullable(Codecs.blob),
        read: (entity) => entity.bytes);
    final type = _type([_id(), _name(), revision, blob]);
    final bytes = Uint8List.fromList([1, 2]);
    final entity = _Entity(id: BigInt.zero, revision: 7, bytes: bytes);
    final snapshot = type.encode(entity);
    bytes[0] = 9;
    entity.name = 'edited';
    expect(snapshot, {
      'id': BigInt.zero,
      'name': 'name',
      'revision': BigInt.from(7),
      'bytes': Uint8List.fromList([1, 2])
    });
    expect(blob.decodeValue(snapshot['bytes']), [1, 2]);
  });

  test(
      'row reader snapshots values, resolves ASCII case and distinguishes NULL',
      () {
    final bytes = Uint8List.fromList([1, 2]);
    final input = <String, Object?>{
      'ID': BigInt.one,
      'v': bytes,
      'null': null,
      'Å': 1,
      'å': 2
    };
    final row = RowReader(input);
    input.clear();
    bytes[0] = 9;
    expect(row.raw('id'), BigInt.one);
    expect(row.raw('v'), [1, 2]);
    (row.raw('v') as Uint8List)[0] = 8;
    expect(row.raw('v'), [1, 2]);
    expect(row.raw('null'), isNull);
    expect(row.raw('Å'), BigInt.one);
    expect(row.raw('å'), BigInt.two);
    expect(() => row.raw('absent'), mappingError);
    expect(() => RowReader({'a': 1, 'A': 2}), mappingError);
    expect(row.read(_id()), BigInt.one);
    expect(() => row.read(_name()), mappingError);
  });

  test('column helpers wrap codec/read failures without publishing values', () {
    final column = Column<_Entity, String>(
        property: 'secret', codec: const _BadCodec(), read: (_) => 'sensitive');
    expect(
        () => column.encodeValue('sensitive'),
        throwsA(isA<OrmCodecException>()
            .having((error) => error.message, 'context', contains('secret'))
            .having((error) => error.toString(), 'redaction',
                isNot(contains('sensitive')))));
    expect(
        () => column.decodeValue('sensitive'),
        throwsA(isA<OrmCodecException>()
            .having((error) => error.cause, 'cause', isA<StateError>())));
    final badRead = Column<_Entity, String>(
        property: 'getter',
        codec: Codecs.text,
        read: (_) => throw StateError('getter failed'));
    expect(() => badRead.readEncoded(_Entity()),
        throwsA(isA<OrmCodecException>()));
    expect(() => _name().encodeValue(1), throwsA(isA<OrmCodecException>()));
  });

  test('heterogeneous metadata invokes typed setters and reconstruction safely',
      () {
    final id = _id();
    final Column<dynamic, dynamic> erased = id;
    final entity = _Entity();
    expect(erased.writable, isTrue);
    erased.writeEncoded(entity, BigInt.from(42));
    expect(entity.id, BigInt.from(42));
    expect(() => erased.writeEncoded(entity, 'wrong type'),
        throwsA(isA<OrmCodecException>()));
    expect(entity.id, BigInt.from(42));
    final Column<dynamic, dynamic> readOnly = _name();
    expect(readOnly.writable, isFalse);
    expect(() => readOnly.writeEncoded(entity, 'new name'), mappingError);
    final EntityType<dynamic> type = EntityType<_Entity>(
        tableName: 'reconstructed',
        columns: [id],
        create: (row) => _Entity(id: row.read(id)),
        applyStoreValues: (previous, row) =>
            _Entity(id: row.read(id), name: previous.name));
    expect(type.canApplyStoreValues, isTrue);
    final replacement = type.applyValues(entity, RowReader({'id': BigInt.one}));
    expect(replacement, isA<_Entity>());
    expect((replacement as _Entity).id, BigInt.one);
    expect(replacement.name, entity.name);
    final plain = _type([id]);
    expect(plain.canApplyStoreValues, isFalse);
    expect(() => plain.applyValues(entity, RowReader({'id': BigInt.one})),
        mappingError);
  });

  test(
      'entity keys keep structural equality and stable hash after blob mutation',
      () {
    final bytes = Uint8List.fromList([1, 2]);
    final key = EntityKey([12, 'a', bytes, null]);
    final equal = EntityKey([
      BigInt.from(12),
      'a',
      Uint8List.fromList([1, 2]),
      null
    ]);
    final hash = key.hashCode;
    final map = {key: 'present'};
    bytes[0] = 9;
    (key.values[2] as Uint8List)[0] = 8;
    expect(key, equal);
    expect(key.hashCode, hash);
    expect(key.hashCode, equal.hashCode);
    expect(map[equal], 'present');
    expect(key, isNot(EntityKey([12, 'a'])));
    expect(
        key,
        isNot(EntityKey([
          12,
          'b',
          Uint8List.fromList([1, 2]),
          null
        ])));
    expect(() => key.values.clear(), throwsUnsupportedError);
  });

  group('foreign keys', () {
    late Column<_Entity, BigInt> parentId;
    late Column<_Entity, String> parentName;
    late EntityType<_Entity> parent;
    late Column<_Entity, BigInt> childId;
    late Column<_Entity, BigInt?> childParent;
    late EntityType<_Entity> child;
    setUp(() {
      parentId = _assignedId();
      parentName = _name(unique: true);
      parent = _type([parentId, parentName], table: 'parents');
      childId = _assignedId();
      childParent = Column(
          property: 'parentId',
          codec: Codecs.nullable(Codecs.bigInt),
          read: (_) => null);
      child = _type([childId, childParent], table: 'children');
    });
    ForeignKey<_Entity, _Entity> relation(
            {String name = 'parent',
            List<Column<_Entity, dynamic>>? local,
            List<Column<_Entity, dynamic>>? target,
            ForeignKeyAction action = ForeignKeyAction.noAction}) =>
        ForeignKey(
            name: name,
            child: child,
            parent: parent,
            columns: local ?? [childParent],
            targetColumns: target ?? [parentId],
            onDelete: action);

    test(
        'nullable local codec agrees with required parent and model registration',
        () {
      final key = relation(action: ForeignKeyAction.setNull);
      final relations = <ForeignKey<dynamic, dynamic>>[key];
      final model = DbModel([parent, child], foreignKeys: relations);
      relations.clear();
      expect(model.foreignKeys, [key]);
      expect(key.columns, [childParent]);
      expect(key.targetColumns, [parentId]);
      expect(key.onDelete, ForeignKeyAction.setNull);
      expect(() => key.columns.clear(), throwsUnsupportedError);
      expect(() => key.targetColumns.clear(), throwsUnsupportedError);
      expect(() => model.foreignKeys.clear(), throwsUnsupportedError);
      expect(() => DbModel([child], foreignKeys: [key]), mappingError);
      expect(
          () => DbModel([parent, child],
              foreignKeys: [key, relation(name: 'PARENT')]),
          mappingError);
    });

    test('width, ownership, duplicate and semantic codec mismatches reject',
        () {
      expect(() => relation(local: []), mappingError);
      expect(
          () => relation(
              local: [childParent, childParent], target: [parentId, parentId]),
          mappingError);
      expect(() => relation(local: [parentId]), mappingError);
      expect(() => relation(target: [childId]), mappingError);
      expect(() => relation(target: [parentName]), mappingError);
      final intLocal = Column<_Entity, int>(
          property: 'p', codec: Codecs.integer, read: (_) => 1);
      final integerChild = _type([childId, intLocal], table: 'c2');
      expect(
          () => ForeignKey(
              name: 'p',
              child: integerChild,
              parent: parent,
              columns: [intLocal],
              targetColumns: [parentId]),
          mappingError);
    });

    test('target must be primary or separately unique', () {
      final nonunique = _name();
      final otherParent = _type([parentId, nonunique], table: 'other_parents');
      final textLocal = Column<_Entity, String>(
          property: 'p', codec: Codecs.text, read: (_) => '');
      final otherChild = _type([childId, textLocal], table: 'other_children');
      expect(
          () => ForeignKey(
              name: 'p',
              child: otherChild,
              parent: otherParent,
              columns: [textLocal],
              targetColumns: [nonunique]),
          mappingError);
      final indexed = _type([parentId, nonunique],
          table: 'indexed_parents',
          indexes: [
            OrmIndex(name: 'parent_name', columns: [nonunique], unique: true)
          ]);
      final key = ForeignKey(
          name: 'p',
          child: otherChild,
          parent: indexed,
          columns: [textLocal],
          targetColumns: [nonunique]);
      expect(DbModel([indexed, otherChild], foreignKeys: [key]).foreignKeys,
          [key]);
    });

    test('SET NULL and SET DEFAULT validate local action prerequisites', () {
      expect(() => relation(local: [childId], action: ForeignKeyAction.setNull),
          mappingError);
      expect(
          () => relation(local: [childId], action: ForeignKeyAction.setDefault),
          mappingError);
      expect(relation(action: ForeignKeyAction.setDefault).onDelete,
          ForeignKeyAction.setDefault);
      final local = Column<_Entity, BigInt>(
          property: 'p',
          codec: Codecs.bigInt,
          read: (_) => BigInt.zero,
          defaultSql: '0');
      final defaultChild = _type([childId, local], table: 'default_children');
      expect(
          ForeignKey(
                  name: 'p',
                  child: defaultChild,
                  parent: parent,
                  columns: [local],
                  targetColumns: [parentId],
                  onUpdate: ForeignKeyAction.setDefault)
              .onUpdate,
          ForeignKeyAction.setDefault);
    });

    test('composite foreign keys follow explicit pair order and uniqueness',
        () {
      final pId = _assignedId(order: 1), pName = _name(order: 0);
      final compositeParent = _type([pId, pName], table: 'composite_parent');
      final localName = Column<_Entity, String?>(
          property: 'pName',
          codec: Codecs.nullable(Codecs.text),
          read: (_) => null);
      final compositeChild =
          _type([childId, childParent, localName], table: 'composite_child');
      final key = ForeignKey(
          name: 'p',
          child: compositeChild,
          parent: compositeParent,
          columns: [childParent, localName],
          targetColumns: [pId, pName],
          deferred: true,
          onDelete: ForeignKeyAction.setNull);
      expect(key.deferred, isTrue);
      expect(
          DbModel([compositeParent, compositeChild], foreignKeys: [key])
              .foreignKeys,
          [key]);
    });
  });
}
