import 'dart:async';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class _Item {
  _Item(this.id, this.name, this.score, this.active, this.payload, this.amount,
      this.created);
  final BigInt id;
  String name;
  final int? score;
  final bool active;
  final Uint8List payload;
  final double amount;
  final DateTime created;
}

final class _Mapping {
  _Mapping() {
    id = Column(
        property: 'id',
        name: 'id key',
        codec: Codecs.bigInt,
        read: (item) => item.id,
        keyOrder: 0);
    name = Column(
        property: 'name',
        name: 'display"name',
        codec: Codecs.text,
        read: (item) => item.name);
    score = Column(
        property: 'score',
        name: 'rank',
        codec: Codecs.nullable(Codecs.integer),
        read: (item) => item.score);
    active = Column(
        property: 'active',
        name: 'is_active',
        codec: Codecs.boolean,
        read: (item) => item.active);
    payload = Column(
        property: 'payload',
        name: 'data',
        codec: Codecs.blob,
        read: (item) => item.payload);
    amount = Column(
        property: 'amount',
        name: 'cost',
        codec: Codecs.real,
        read: (item) => item.amount);
    created = Column(
        property: 'created',
        name: 'created_at',
        codec: Codecs.dateTime,
        read: (item) => item.created);
    type = EntityType(
        tableName: 'select "récords"',
        columns: [id, name, score, active, payload, amount, created],
        create: (row) => _Item(
            row.read(id),
            row.read(name),
            row.read(score),
            row.read(active),
            row.read(payload),
            row.read(amount),
            row.read(created)));
  }
  late final Column<_Item, BigInt> id;
  late final Column<_Item, String> name;
  late final Column<_Item, int?> score;
  late final Column<_Item, bool> active;
  late final Column<_Item, Uint8List> payload;
  late final Column<_Item, double> amount;
  late final Column<_Item, DateTime> created;
  late final EntityType<_Item> type;
}

final class _RecordingConnection extends OrmConnection {
  _RecordingConnection(this.delegate);
  final OrmConnection delegate;
  final List<(String, List<Object?>)> queries = [];
  @override
  bool get inTransaction => delegate.inTransaction;
  @override
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    queries.add((sql, parameters.map(copyOrmValue).toList()));
    return delegate.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      delegate.execute(sql, parameters);
  @override
  Future<void> close() => delegate.close();
}

Future<List<BigInt>> _ids(TypedQuery<_Item> query) async =>
    (await query.toList()).map((item) => item.id).toList();
List<BigInt> _integers(List<int> values) => values.map(BigInt.from).toList();

void main() {
  for (final encoding in [1, 2, 3]) {
    group('typed queries encoding $encoding', () {
      late MutableSqliteDatabase db;
      late _Mapping mapping;
      late _RecordingConnection connection;
      late TypedQuery<_Item> query;

      setUp(() async {
        mapping = _Mapping();
        db = await MutableSqliteDatabase.create(encoding: encoding);
        connection = _RecordingConnection(MutableDatabaseConnection(db));
        query = TypedQuery(type: mapping.type, connection: connection);
        await db.execute(
            'CREATE TABLE ${quoteIdentifier(mapping.type.tableName)}('
            '${mapping.type.columns.map((column) => '${quoteIdentifier(column.sqlName)} ${column.codec.sqlType}${column.keyOrder != null ? ' PRIMARY KEY' : ''}${column.nullable ? '' : ' NOT NULL'}').join(', ')})');
        final names = ['Ada', 'Bob', 'Cara', "x') OR 1=1 --", 'Éva'];
        final scores = [3, null, 1, 3, 0];
        for (var index = 0; index < names.length; index++) {
          final item = _Item(
              BigInt.from(index + 1),
              names[index],
              scores[index],
              index.isEven,
              Uint8List.fromList(index == 0 ? [1, 2] : [index + 1]),
              index == 0 ? 1.5 : (index + 1).toDouble(),
              DateTime.utc(2020, 1, index + 1));
          await db.execute(
              'INSERT INTO ${quoteIdentifier(mapping.type.tableName)} VALUES(?,?,?,?,?,?,?)',
              mapping.type.columns
                  .map((column) => column.readEncoded(item))
                  .toList());
        }
      });
      tearDown(() async {
        await connection.close();
        await db.close();
      });

      test('identifiers are quoted and values remain bound', () async {
        final filtered = query
            .where(mapping.name.eq("x') OR 1=1 --"))
            .orderBy([mapping.id.asc()]);
        final command = filtered.toSql();
        expect(command.sql,
            'SELECT "id key", "display""name", "rank", "is_active", "data", "cost", "created_at" FROM "select ""récords""" WHERE "display""name" = ? ORDER BY "id key" ASC');
        expect(command.parameters, ["x') OR 1=1 --"]);
        expect(await _ids(filtered), _integers([4]));
        expect(await query.count(), BigInt.from(5));
      });

      test('nullable predicates retain SQLite three-valued logic', () async {
        expect(await _ids(query.where(mapping.score.eq(null))), _integers([2]));
        expect(await _ids(query.where(mapping.score.notEq(null))),
            _integers([1, 3, 4, 5]));
        expect(await _ids(query.where(mapping.score.isNull())), _integers([2]));
        expect(await _ids(query.where(mapping.score.isNotNull())),
            _integers([1, 3, 4, 5]));
        expect(await _ids(query.where(mapping.score.eq(3).not())),
            _integers([3, 5]));
        expect(
            await _ids(query.where(mapping.score.notEq(3))), _integers([3, 5]));
        expect(await _ids(query.where(mapping.score.lt(null))), isEmpty);
        final predicate = (mapping.score.eq(3) | mapping.score.isNull()) &
            mapping.active.eq(false);
        expect(await _ids(query.where(predicate)), _integers([2, 4]));
      });

      test('comparison, bool, date and blob values use codecs', () async {
        expect(await _ids(query.where(mapping.score.lt(2))), _integers([3, 5]));
        expect(
            await _ids(query.where(mapping.score.lte(1))), _integers([3, 5]));
        expect(await _ids(query.where(mapping.score.gt(1))), _integers([1, 4]));
        expect(
            await _ids(query.where(mapping.score.gte(3))), _integers([1, 4]));
        expect(await _ids(query.where(mapping.active.eq(true))),
            _integers([1, 3, 5]));
        expect(
            await _ids(query.where(mapping.amount.gt(3))), _integers([4, 5]));
        expect(
            await _ids(
                query.where(mapping.created.gte(DateTime.utc(2020, 1, 3)))),
            _integers([3, 4, 5]));
        expect(
            await _ids(
                query.where(mapping.payload.eq(Uint8List.fromList([1, 2])))),
            _integers([1]));
      });

      test('IN snapshots values and preserves NULL and empty-list behavior',
          () async {
        final values = <int?>[null, 3];
        final filtered = query.where(mapping.score.inValues(values));
        values.clear();
        expect(await _ids(filtered), _integers([1, 4]));
        expect(await _ids(query.where(mapping.score.inValues([]))), isEmpty);
        expect(await _ids(query.where(mapping.score.inValues([]).not())),
            _integers([1, 2, 3, 4, 5]));
        expect(
            await _ids(query.where(mapping.score.inValues([null]))), isEmpty);
        expect(await _ids(query.where(mapping.score.inValues([null, 3]).not())),
            isEmpty);
        expect(await _ids(query.where(mapping.score.inValues([3]).not())),
            _integers([3, 5]));
      });

      test('bound blobs and command parameters cannot mutate query state',
          () async {
        final bytes = Uint8List.fromList([1, 2]);
        final filtered = query.where(mapping.payload.eq(bytes));
        bytes[0] = 99;
        final command = filtered.toSql();
        (command.parameters.single as Uint8List)[0] = 88;
        expect(command.parameters.single, [1, 2]);
        expect(() => command.parameters.add(null), throwsUnsupportedError);
        expect(await _ids(filtered), _integers([1]));
      });

      test('ordering supports multiple terms and explicit NULL placement',
          () async {
        expect(
            await _ids(query.orderBy([mapping.score.asc(), mapping.id.desc()])),
            _integers([2, 5, 3, 4, 1]));
        expect(
            await _ids(query.orderBy(
                [mapping.score.desc(nullsFirst: false), mapping.id.asc()])),
            _integers([1, 4, 3, 5, 2]));
        expect(
            await _ids(query.orderBy(
                [mapping.score.desc(nullsFirst: true), mapping.id.asc()])),
            _integers([2, 1, 4, 3, 5]));
        expect(
            await _ids(query.orderBy(
                [mapping.score.asc(nullsFirst: false), mapping.id.asc()])),
            _integers([5, 3, 1, 4, 2]));
        expect(
            await _ids(query.orderBy([mapping.score.desc(), mapping.id.asc()])),
            _integers([1, 4, 3, 5, 2]));
      });

      test('nested predicates and count retain placeholder encounter order',
          () async {
        final filtered = query
            .where((mapping.score.inValues([1, 3]) &
                    mapping.name.notEq("x') OR 1=1 --")) |
                (mapping.score.eq(null) & mapping.active.eq(false)))
            .where(mapping.id.gte(BigInt.two))
            .orderBy([mapping.id.desc()])
            .skip(1)
            .take(2);
        final command = filtered.toSql();
        final parameters = [
          BigInt.one,
          BigInt.from(3),
          "x') OR 1=1 --",
          BigInt.zero,
          BigInt.two,
          BigInt.two,
          BigInt.one
        ];
        expect(command.parameters, parameters);
        expect(await _ids(filtered), _integers([2]));
        expect(await filtered.count(), BigInt.one);
        expect(connection.queries.last.$1,
            'SELECT COUNT(*) FROM (${command.sql}) AS "_orm_count"');
        expect(connection.queries.last.$2, parameters);
      });

      test('builders are immutable and ordering snapshots the input list',
          () async {
        final order = [mapping.id.desc()];
        final ordered = query.orderBy(order);
        order.clear();
        expect(await _ids(ordered.take(2)), _integers([5, 4]));
        expect(await _ids(query.take(2)), _integers([1, 2]));
        expect(await _ids(ordered.orderBy([mapping.id.asc()]).take(2)),
            _integers([1, 2]));
        expect(
            await _ids(query
                .where(mapping.id.gt(BigInt.two))
                .where(mapping.active.eq(true))),
            _integers([3, 5]));
      });

      test('pagination composes intervals and counts the selected interval',
          () async {
        final ordered = query.orderBy([mapping.id.asc()]);
        expect(await _ids(ordered.skip(1).take(3).skip(1).take(8)),
            _integers([3, 4]));
        expect(await _ids(ordered.take(2).take(5)), _integers([1, 2]));
        expect(await _ids(ordered.take(2).skip(3)), isEmpty);
        expect(await _ids(ordered.skip(1).skip(2)), _integers([4, 5]));
        expect(await ordered.skip(2).take(2).count(), BigInt.two);
        expect(await ordered.take(0).count(), BigInt.zero);
        expect(await ordered.skip(99).any(), isFalse);
        expect(await ordered.take(0).any(), isFalse);
      });

      test(
          'terminals preserve zero limits and validate cardinality before mapping',
          () async {
        var mapped = 0;
        final tracked = TypedQuery(
            type: mapping.type,
            connection: connection,
            materialize: (row) {
              mapped++;
              return mapping.type.create(row);
            });
        expect((await tracked.firstOrNull())!.id, BigInt.one);
        expect(await tracked.take(0).firstOrNull(), isNull);
        expect(mapped, 1);
        await expectLater(tracked.single(), throwsA(isA<OrmStateException>()));
        await expectLater(
            tracked.take(0).single(), throwsA(isA<OrmStateException>()));
        expect(mapped, 1);
        expect((await tracked.where(mapping.id.eq(BigInt.two)).single()).id,
            BigInt.two);
        expect(
            await tracked.where(mapping.id.eq(BigInt.from(99))).firstOrNull(),
            isNull);
        expect(await tracked.any(), isTrue);
      });

      test(
          'asNoTracking bypasses identity materialization without changing SQL',
          () async {
        final identities = <BigInt, _Item>{};
        var mapped = 0;
        final tracked = TypedQuery(
            type: mapping.type,
            connection: connection,
            materialize: (row) {
              mapped++;
              return identities.putIfAbsent(
                  row.read(mapping.id), () => mapping.type.create(row));
            });
        final filtered = tracked.where(mapping.id.eq(BigInt.one));
        final first = await filtered.single();
        first.name = 'local edit';
        expect(identical(await filtered.single(), first), isTrue);
        final detached = await filtered.asNoTracking().single();
        expect(identical(detached, first), isFalse);
        expect(detached.name, 'Ada');
        expect(first.name, 'local edit');
        expect(mapped, 2);
        expect(filtered.toSql().sql, filtered.asNoTracking().toSql().sql);
      });

      test('query columns must belong to the exact mapping, including empty IN',
          () {
        final other = _Mapping();
        expect(() => query.where(other.id.eq(BigInt.one)),
            throwsA(isA<OrmMappingException>()));
        expect(() => query.where(other.score.inValues([])),
            throwsA(isA<OrmMappingException>()));
        expect(() => query.orderBy([other.id.asc()]),
            throwsA(isA<OrmMappingException>()));
        expect(connection.queries, isEmpty);
      });

      test('invalid bound values and pagination fail before execution', () {
        expect(() => mapping.amount.eq(double.nan),
            throwsA(isA<OrmCodecException>()));
        expect(() => mapping.amount.inValues([double.infinity]),
            throwsA(isA<OrmCodecException>()));
        expect(() => query.skip(-1), throwsRangeError);
        expect(() => query.take(-1), throwsRangeError);
        expect(() => query.take(9007199254740992), throwsRangeError);
        expect(() => query.skip(9007199254740991).skip(1), throwsRangeError);
        final parameters = query.skip(9007199254740991).toSql().parameters;
        expect(parameters, [-BigInt.one, BigInt.parse('9007199254740991')]);
        expect(connection.queries, isEmpty);
      });

      test(
          'full signed64 keys remain exact through predicates and materialization',
          () async {
        for (final boundary in [
          BigInt.parse('-9223372036854775808'),
          BigInt.parse('9223372036854775807')
        ]) {
          await db.execute(
              'INSERT INTO ${quoteIdentifier(mapping.type.tableName)} VALUES(?,?,?,?,?,?,?)',
              [
                boundary,
                'boundary',
                1,
                BigInt.one,
                Uint8List(0),
                0.0,
                Codecs.dateTime.encode(DateTime.utc(2020))
              ]);
          final value = await query.where(mapping.id.eq(boundary)).single();
          expect(value.id, boundary);
          expect(
              await query.where(mapping.id.eq(boundary)).count(), BigInt.one);
        }
      });
    });
  }

  test('every terminal uses exactly one supplied operation runner', () async {
    final mapping = _Mapping();
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final connection = _RecordingConnection(MutableDatabaseConnection(db));
    await db.execute('CREATE TABLE ${quoteIdentifier(mapping.type.tableName)}('
        '${mapping.type.columns.map((column) => '${quoteIdentifier(column.sqlName)} ${column.codec.sqlType}').join(', ')})');
    var tail = Future<void>.value();
    var operations = 0;
    var active = false;
    Future<R> serialize<R>(Future<R> Function() operation) {
      final result = tail.then((_) async {
        expect(active, isFalse);
        active = true;
        operations++;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return await operation();
        } finally {
          active = false;
        }
      });
      tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      return result;
    }

    final query = TypedQuery(
        type: mapping.type, connection: connection, serialize: serialize);
    await Future.wait<Object?>([
      query.toList(),
      query.firstOrNull(),
      query.count(),
      query.any(),
      query.asNoTracking().toList(),
      expectLater(query.single(), throwsA(isA<OrmStateException>()))
    ]);
    expect(operations, 6);
    expect(connection.queries, hasLength(6));
  });
}
