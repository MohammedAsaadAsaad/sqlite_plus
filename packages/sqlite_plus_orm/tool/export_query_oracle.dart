// Development-only exporter. Native SQLite is never used by the ORM runtime.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final class _Sample {
  _Sample(this.id, this.label, this.rank, this.flag, this.bytes, this.amount,
      this.created);
  final BigInt id;
  final String label;
  final int? rank;
  final bool flag;
  final Uint8List bytes;
  final double amount;
  final DateTime created;
}

final class _Mapping {
  _Mapping() {
    id = Column<_Sample, BigInt>(
        property: 'id',
        name: 'id key',
        codec: Codecs.bigInt,
        read: (value) => value.id,
        keyOrder: 0);
    label = Column<_Sample, String>(
        property: 'label',
        name: 'display"name',
        codec: Codecs.text,
        read: (value) => value.label);
    rank = Column<_Sample, int?>(
        property: 'rank',
        codec: Codecs.nullable(Codecs.integer),
        read: (value) => value.rank);
    flag = Column<_Sample, bool>(
        property: 'flag', codec: Codecs.boolean, read: (value) => value.flag);
    bytes = Column<_Sample, Uint8List>(
        property: 'bytes', codec: Codecs.blob, read: (value) => value.bytes);
    amount = Column<_Sample, double>(
        property: 'amount', codec: Codecs.real, read: (value) => value.amount);
    created = Column<_Sample, DateTime>(
        property: 'created',
        codec: Codecs.dateTime,
        read: (value) => value.created);
    type = EntityType<_Sample>(
        tableName: 'select "récords"',
        columns: [id, label, rank, flag, bytes, amount, created],
        create: (row) => _Sample(
            row.read(id),
            row.read(label),
            row.read(rank),
            row.read(flag),
            row.read(bytes),
            row.read(amount),
            row.read(created)));
  }

  late final Column<_Sample, BigInt> id;
  late final Column<_Sample, String> label;
  late final Column<_Sample, int?> rank;
  late final Column<_Sample, bool> flag;
  late final Column<_Sample, Uint8List> bytes;
  late final Column<_Sample, double> amount;
  late final Column<_Sample, DateTime> created;
  late final EntityType<_Sample> type;
}

Object? _encode(Object? value) => switch (value) {
      BigInt() => {'integer': value.toString()},
      Uint8List() => {
          'blob':
              value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()
        },
      _ => value
    };

final class _RecordingConnection extends OrmConnection {
  _RecordingConnection(this.delegate);
  final OrmConnection delegate;
  final List<Map<String, Object?>> cases = [];
  String label = '';

  @override
  bool get inTransaction => delegate.inTransaction;

  @override
  Future<QueryResult> query(String sql,
      [List<Object?> parameters = const []]) async {
    final result = await delegate.query(sql, parameters);
    cases.add({
      'case': label,
      'sql': sql,
      'parameters': parameters.map(_encode).toList(),
      'columns': result.columns,
      'rows': result.rows.map((row) => row.map(_encode).toList()).toList()
    });
    return result;
  }

  @override
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      delegate.execute(sql, parameters);

  @override
  Future<void> close() => delegate.close();
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Expected an output directory');
  }
  final directory = Directory(arguments.single)..createSync(recursive: true);
  for (final encoding in [1, 2, 3]) {
    final database = await MutableSqliteDatabase.create(encoding: encoding);
    final connection =
        _RecordingConnection(MutableDatabaseConnection(database));
    try {
      final mapping = _Mapping();
      await database.execute(
          'CREATE TABLE ${quoteIdentifier(mapping.type.tableName)}('
          '${mapping.type.columns.map((column) => '${quoteIdentifier(column.sqlName)} ${column.codec.sqlType}${column.keyOrder != null ? ' PRIMARY KEY' : ''}${column.nullable ? '' : ' NOT NULL'}').join(', ')})');
      final minimum = BigInt.parse('-9223372036854775808');
      final maximum = BigInt.parse('9223372036854775807');
      final keys = [
        minimum,
        -BigInt.one,
        BigInt.zero,
        BigInt.one,
        BigInt.two,
        BigInt.from(3),
        maximum
      ];
      final labels = [
        '03',
        '3',
        '3.0',
        "x') OR 1=1 --",
        'Éva😀',
        'a\u0000b',
        ''
      ];
      final ranks = [null, 0, 1, 3, 3, null, -1];
      for (var index = 0; index < keys.length; index++) {
        final item = _Sample(
            keys[index],
            labels[index],
            ranks[index],
            index.isEven,
            Uint8List.fromList(index == 0 ? [] : [index, 255]),
            index == 0 ? -1.5 : index.toDouble(),
            DateTime.utc(2020, 1, index + 1, 0, 0, 0, 0, 123));
        await database.execute(
            'INSERT INTO ${quoteIdentifier(mapping.type.tableName)} VALUES(?,?,?,?,?,?,?)',
            mapping.type.columns
                .map((column) => column.readEncoded(item))
                .toList());
      }
      // SQLite affinity converts these differently typed inputs to the declared
      // storage types before typed predicates bind their codec-encoded values.
      await database.execute(
          'UPDATE ${quoteIdentifier(mapping.type.tableName)} SET "rank" = ?, "amount" = ?, "display""name" = ? WHERE "id key" = ?',
          ['03', '3.0', BigInt.from(3), BigInt.zero]);

      final query = TypedQuery(type: mapping.type, connection: connection);
      final ordered = query.orderBy([mapping.id.asc()]);
      final tests = <(String, TypedQuery<_Sample>)>[
        ('all', ordered),
        ('null equality', ordered.where(mapping.rank.eq(null))),
        ('null inequality', ordered.where(mapping.rank.notEq(null))),
        ('null comparison', ordered.where(mapping.rank.lt(null))),
        ('is null', ordered.where(mapping.rank.isNull())),
        ('is not null', ordered.where(mapping.rank.isNotNull())),
        ('integer equality', ordered.where(mapping.rank.eq(3))),
        ('integer inequality', ordered.where(mapping.rank.notEq(3))),
        ('integer less', ordered.where(mapping.rank.lt(3))),
        ('integer less equal', ordered.where(mapping.rank.lte(3))),
        ('integer greater', ordered.where(mapping.rank.gt(0))),
        ('integer greater equal', ordered.where(mapping.rank.gte(0))),
        ('not comparison', ordered.where(mapping.rank.eq(3).not())),
        ('in empty', ordered.where(mapping.rank.inValues([]))),
        ('not in empty', ordered.where(mapping.rank.inValues([]).not())),
        ('in null', ordered.where(mapping.rank.inValues([null]))),
        ('not in null', ordered.where(mapping.rank.inValues([null]).not())),
        ('in mixed null', ordered.where(mapping.rank.inValues([null, 3]))),
        (
          'not in mixed null',
          ordered.where(mapping.rank.inValues([null, 3]).not())
        ),
        ('in duplicate', ordered.where(mapping.rank.inValues([3, 3, 0]))),
        (
          'nested precedence',
          ordered.where(((mapping.rank.eq(3) | mapping.rank.isNull()) &
                  mapping.flag.eq(false)) |
              (mapping.label.eq('03') & mapping.id.eq(minimum)))
        ),
        (
          'nested negation',
          ordered.where((mapping.rank.eq(3) | mapping.rank.isNull()).not())
        ),
        (
          'repeated where',
          ordered.where(mapping.rank.gte(0)).where(mapping.flag.eq(true))
        ),
        ('text numeric affinity', ordered.where(mapping.label.eq('3'))),
        ('text numeric spelling', ordered.where(mapping.label.eq('03'))),
        (
          'text injection binding',
          ordered.where(mapping.label.eq("x') OR 1=1 --"))
        ),
        ('text unicode', ordered.where(mapping.label.eq('Éva😀'))),
        ('text NUL', ordered.where(mapping.label.eq('a\u0000b'))),
        ('text ordering comparison', ordered.where(mapping.label.lt('4'))),
        ('minimum integer', ordered.where(mapping.id.eq(minimum))),
        ('maximum integer', ordered.where(mapping.id.eq(maximum))),
        (
          'integer extremes in',
          ordered.where(mapping.id.inValues([minimum, maximum]))
        ),
        ('boolean true', ordered.where(mapping.flag.eq(true))),
        ('boolean false', ordered.where(mapping.flag.eq(false))),
        ('real equality affinity', ordered.where(mapping.amount.eq(3.0))),
        ('real comparison', ordered.where(mapping.amount.gt(2.5))),
        ('blob empty', ordered.where(mapping.bytes.eq(Uint8List(0)))),
        (
          'blob bytes',
          ordered.where(mapping.bytes.eq(Uint8List.fromList([2, 255])))
        ),
        (
          'blob membership',
          ordered.where(mapping.bytes.inValues([
            Uint8List(0),
            Uint8List.fromList([2, 255])
          ]))
        ),
        (
          'date timezone normalization',
          ordered.where(mapping.created
              .eq(DateTime.parse('2020-01-03T01:00:00.000123+01:00')))
        ),
        (
          'date comparison',
          ordered.where(mapping.created.gte(DateTime.utc(2020, 1, 4)))
        ),
        (
          'ascending default nulls',
          query.orderBy([mapping.rank.asc(), mapping.id.desc()])
        ),
        (
          'descending default nulls',
          query.orderBy([mapping.rank.desc(), mapping.id.asc()])
        ),
        (
          'ascending nulls first',
          query.orderBy([mapping.rank.asc(nullsFirst: true), mapping.id.asc()])
        ),
        (
          'ascending nulls last',
          query.orderBy([mapping.rank.asc(nullsFirst: false), mapping.id.asc()])
        ),
        (
          'descending nulls first',
          query.orderBy([mapping.rank.desc(nullsFirst: true), mapping.id.asc()])
        ),
        (
          'descending nulls last',
          query
              .orderBy([mapping.rank.desc(nullsFirst: false), mapping.id.asc()])
        ),
        ('zero take', ordered.take(0)),
        ('offset only', ordered.skip(2)),
        ('take', ordered.take(3)),
        ('composed interval', ordered.skip(1).take(4).skip(1).take(8)),
        ('exhausted interval', ordered.take(2).skip(3)),
        ('portable maximum take', ordered.take(9007199254740991)),
        ('portable maximum offset', ordered.skip(9007199254740991)),
        (
          'bound filter pagination',
          ordered
              .where(mapping.rank.inValues([0, 3]))
              .where(mapping.label.notEq("x') OR 1=1 --"))
              .skip(1)
              .take(2)
        ),
        ('no tracking', ordered.asNoTracking())
      ];

      for (final (name, test) in tests) {
        connection.label = '$name/toList';
        final rows = await test.toList();
        connection.label = '$name/count';
        final count = await test.count();
        connection.label = '$name/firstOrNull';
        final first = await test.firstOrNull();
        connection.label = '$name/any';
        final any = await test.any();
        if (count != BigInt.from(rows.length) ||
            first?.id != (rows.isEmpty ? null : rows.first.id) ||
            any != rows.isNotEmpty) {
          throw StateError('Typed terminal results disagree for $name');
        }
      }
      File('${directory.path}/$encoding.db')
          .writeAsBytesSync(database.exportImage());
      File('${directory.path}/$encoding.json').writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(connection.cases)}\n');
    } finally {
      await connection.close();
      await database.close();
    }
  }
}
