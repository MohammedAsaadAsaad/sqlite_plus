import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

final class _EchoModule implements VirtualTableModule {
  @override
  String get name => 'Echo';
  @override
  List<String> get columns => ['value'];
  @override
  List<List<Object?>> read(String table, List<String> arguments) => [
        for (final argument in arguments) [argument]
      ];
}

final class _PairModule implements VirtualTableModule {
  @override
  String get name => 'pair';
  @override
  List<String> get columns => ['left', 'right'];
  @override
  List<List<Object?>> read(String table, List<String> arguments) => [
        [arguments.first, int.parse(arguments.last)],
        [
          null,
          Uint8List.fromList([1, 2])
        ]
      ];
}

final class _BrokenModule implements VirtualTableModule {
  _BrokenModule(this.mode);
  final String mode;
  @override
  String get name => 'broken';
  @override
  List<String> get columns => ['value'];
  @override
  List<List<Object?>> read(String table, List<String> arguments) {
    if (mode == 'width') {
      return [[]];
    }
    if (mode == 'type') {
      return [
        <Object?>[Object()]
      ];
    }
    if (mode == 'throw') {
      throw StateError('module crashed');
    }
    return List.generate(100001, (index) => ['$index']);
  }
}

void main() {
  test('a registered module is visible in the schema and readable from SQL',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(_EchoModule());
    await database
        .execute("CREATE VIRTUAL TABLE words USING echo('one', two, 3)");
    final schema = await database.query(
        "SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema WHERE name = 'words'");
    expect(schema.rows, [
      [
        'table',
        'words',
        'words',
        BigInt.zero,
        "CREATE VIRTUAL TABLE words USING echo('one', two, 3)"
      ]
    ]);
    expect(
        (await database.query('SELECT value FROM words ORDER BY value')).rows, [
      ['3'],
      ['one'],
      ['two']
    ]);
    final image = database.exportImage();
    final reopened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(reopened.close);
    reopened.functions.virtualTables.register(_EchoModule());
    expect((await reopened.query('SELECT rowid, value FROM words')).rows, [
      [BigInt.one, 'one'],
      [BigInt.two, 'two'],
      [BigInt.from(3), '3']
    ]);
  });

  test('virtual rows join ordinary tables and keep SQL value types', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(_PairModule());
    await database.execute('CREATE TABLE labels(name TEXT)');
    await database.execute("INSERT INTO labels VALUES ('alpha')");
    await database.execute("CREATE VIRTUAL TABLE pairs USING pair('alpha', 7)");
    final joined = await database.query(
        'SELECT labels.name, pairs.right FROM labels JOIN pairs ON labels.name = pairs.left');
    expect(joined.rows, [
      ['alpha', BigInt.from(7)]
    ]);
    final typed = await database.query('SELECT left, right FROM pairs');
    expect(typed.rows[1][0], isNull);
    expect(typed.rows[1][1], Uint8List.fromList([1, 2]));
  });

  test('unknown modules, reserved names, and bad module output do not commit',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute('CREATE TABLE kept(id INT)');
    final before = database.exportImage();
    await expectLater(
        database.execute('CREATE VIRTUAL TABLE missing USING echo(1)'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such module: echo')));
    expect(database.exportImage(), before);
    database.functions.virtualTables.register(_EchoModule());
    await expectLater(
        database.execute('CREATE VIRTUAL TABLE sqlite_hidden USING echo(1)'),
        throwsA(isA<SqlException>()));
    expect(database.exportImage(), before);
    await database.execute('CREATE VIRTUAL TABLE words USING echo(1)');
    await expectLater(
        database.execute('CREATE VIRTUAL TABLE words USING echo(2)'),
        throwsA(isA<SqlException>()));
    expect(
        (await database.query(
                "SELECT count(*) FROM sqlite_schema WHERE name = 'words'"))
            .rows,
        [
          [BigInt.one]
        ]);
    await database
        .execute('CREATE VIRTUAL TABLE IF NOT EXISTS words USING echo(2)');
    expect((await database.query('SELECT value FROM words')).rows, [
      ['1']
    ]);
    for (final module in [
      _BrokenModule('width'),
      _BrokenModule('type'),
      _BrokenModule('throw'),
      _BrokenModule('limit')
    ]) {
      final fresh = await MutableSqliteDatabase.create();
      addTearDown(fresh.close);
      fresh.functions.virtualTables.register(module);
      await fresh.execute('CREATE VIRTUAL TABLE bad USING broken(1)');
      final image = fresh.exportImage();
      await expectLater(
          fresh.query('SELECT value FROM bad'), throwsA(isA<SqlException>()));
      expect(fresh.exportImage(), image);
    }
    expect(() => database.functions.virtualTables.register(_EchoModule()),
        throwsArgumentError);
    expect((await database.query('SELECT id FROM kept')).rows, isEmpty);
  });
}
