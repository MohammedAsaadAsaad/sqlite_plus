import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('equality and range constraints are consumed and other predicates scan',
      () async {
    final module = _GateModule();
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(module);
    await database.execute('CREATE VIRTUAL TABLE words USING gate()');
    expect(
        (await database.query("SELECT value FROM words WHERE value = 'b'"))
            .rows,
        [
          ['b']
        ]);
    expect(module.seen, ['=:b']);
    expect(module.yielded, 1);
    expect(
        (await database.query('SELECT value FROM words WHERE ? = value', ['c']))
            .rows,
        [
          ['c']
        ]);
    expect(module.seen, ['=:c']);
    expect(
        (await database.query(
                "SELECT value FROM words WHERE value > 'b' ORDER BY value"))
            .rows,
        [
          ['c'],
          ['d']
        ]);
    expect(module.seen, ['>:b']);
    expect(module.yielded, 2);
    expect(
        (await database.query(
                "SELECT value FROM words WHERE 'b' < value ORDER BY value"))
            .rows,
        [
          ['c'],
          ['d']
        ]);
    expect(module.yielded, 2);
    expect(
        (await database.query(
                "SELECT value FROM words WHERE value < 'c' ORDER BY value"))
            .rows,
        [
          ['a'],
          ['b']
        ]);
    expect(module.seen, isEmpty);
    expect(module.yielded, 4);
    expect(
        (await database.query("SELECT value FROM words WHERE value LIKE 'b%'"))
            .rows,
        [
          ['b']
        ]);
    expect(module.seen, isEmpty);
    expect(module.yielded, 4);
  });

  test('hidden columns stay out of SELECT star and CREATE arguments arrive',
      () async {
    final module = _SecretModule();
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(module);
    final before = database.exportImage();
    await expectLater(
        database
            .execute("CREATE VIRTUAL TABLE box(value) USING secret('hunter2')"),
        throwsA(isA<SqlException>()));
    await expectLater(
        database.execute(
            "CREATE VIRTUAL TABLE box(value, token) USING secret('hunter2')"),
        throwsA(isA<SqlException>()));
    expect(database.exportImage(), before);
    await database.execute(
        "CREATE VIRTUAL TABLE box(value, token HIDDEN) USING secret('hunter2')");
    final star = await database.query('SELECT * FROM box');
    expect(star.columns, ['value']);
    expect(star.rows, [
      ['visible']
    ]);
    expect((await database.query('SELECT token FROM box')).rows, [
      ['hunter2']
    ]);
    expect(module.arguments, ['hunter2']);
    await database.execute("CREATE VIRTUAL TABLE plain USING secret('other')");
    expect((await database.query('SELECT token FROM plain')).rows, [
      ['other']
    ]);
  });

  test('named virtual tables and eponymous calls do not mix', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(_EchoModule());
    await database.execute('CREATE TABLE kept(id INT)');
    await database.execute("CREATE VIRTUAL TABLE words USING echo('a')");
    expect((await database.query('SELECT value FROM words')).rows, [
      ['a']
    ]);
    await expectLater(database.query('SELECT value FROM words(1)'),
        throwsA(isA<SqlException>()));
    await expectLater(
        database.query('SELECT id FROM kept(1)'), throwsA(isA<SqlException>()));
    await expectLater(database.query('SELECT value FROM echo(1)'),
        throwsA(isA<SqlException>()));
    expect(
        (await database.query('SELECT value FROM generate_series(1, 2)')).rows,
        [
          [BigInt.one],
          [BigInt.two]
        ]);
    expect(
        (await database.query(
                'SELECT kept.id, value FROM kept, generate_series(4, 4)'))
            .rows,
        isEmpty);
    await database.execute('INSERT INTO kept VALUES (7)');
    expect(
        (await database.query(
                'SELECT value, kept.id FROM generate_series(1, 2), kept ORDER BY value'))
            .rows,
        [
          [BigInt.one, BigInt.from(7)],
          [BigInt.two, BigInt.from(7)]
        ]);
  });

  test('rollback drops virtual schema with the ordinary insert', () async {
    final module = _TxnModule();
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(module);
    await database.execute('CREATE TABLE kept(id INT)');
    await database.execute('BEGIN');
    expect(module.log, ['begin']);
    await database.execute('INSERT INTO kept VALUES (1)');
    await database.execute("CREATE VIRTUAL TABLE words USING txn('a')");
    await database.execute('ROLLBACK');
    expect(module.log, ['begin', 'create', 'rollback']);
    expect(module.rows, isEmpty);
    expect((await database.query('SELECT id FROM kept')).rows, isEmpty);
    expect(
        (await database.query(
                "SELECT count(*) FROM sqlite_schema WHERE name = 'words'"))
            .rows,
        [
          [BigInt.zero]
        ]);
    await database.execute('BEGIN');
    await database.execute('INSERT INTO kept VALUES (2)');
    await database.execute("CREATE VIRTUAL TABLE words USING txn('b')");
    await database.execute('COMMIT');
    expect(module.log.last, 'commit');
    expect((await database.query('SELECT id FROM kept')).rows, [
      [BigInt.two]
    ]);
    expect((await database.query('SELECT value FROM words')).rows, [
      ['b']
    ]);
  });

  test('reopen sees a virtual table and a reserved name is rejected', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(_EchoModule());
    final before = database.exportImage();
    await expectLater(
        database.execute("CREATE VIRTUAL TABLE sqlite_hidden USING echo('a')"),
        throwsA(isA<SqlException>()));
    expect(database.exportImage(), before);
    await database.execute("CREATE VIRTUAL TABLE words USING echo('a')");
    final image = database.exportImage();
    final reopened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(reopened.close);
    reopened.functions.virtualTables.register(_EchoModule());
    expect((await reopened.query('SELECT value FROM words')).rows, [
      ['a']
    ]);
  });

  test('dropping a virtual table leaves the neighbor table and its index',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(_EchoModule());
    await database.execute('CREATE TABLE kept(id INT, name TEXT)');
    await database.execute('CREATE INDEX kept_name ON kept(name)');
    await database.execute("INSERT INTO kept VALUES (1, 'a')");
    await database.execute("CREATE VIRTUAL TABLE words USING echo('z')");
    expect((await database.query('SELECT name FROM kept')).rows, [
      ['a']
    ]);
    await database.execute('DROP TABLE words');
    expect((await database.query('SELECT id, name FROM kept')).rows, [
      [BigInt.one, 'a']
    ]);
    expect(
        (await database.query(
                "SELECT name FROM sqlite_schema WHERE type = 'index' AND name = 'kept_name'"))
            .rows,
        [
          ['kept_name']
        ]);
    expect(
        (await database.query(
                "SELECT count(*) FROM sqlite_schema WHERE name = 'words'"))
            .rows,
        [
          [BigInt.zero]
        ]);
  });

  test('an unknown module writes nothing', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await database.execute('CREATE TABLE kept(id INT)');
    final before = database.exportImage();
    await expectLater(
        database.execute('CREATE VIRTUAL TABLE missing USING absent(1)'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'No such module: absent')));
    expect(database.exportImage(), before);
    expect((await database.query('SELECT id FROM kept')).rows, isEmpty);
  });

  test('generate_series covers start, stop, step, and the integer edges',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    Future<List<Object?>> values(String sql,
            [List<Object?> parameters = const []]) async =>
        (await database.query(sql, parameters))
            .rows
            .map((row) => row.single)
            .toList();
    expect(await values('SELECT value FROM generate_series(1, 5)'),
        [for (var n = 1; n <= 5; n++) BigInt.from(n)]);
    expect(await values('SELECT value FROM generate_series(5, 1, -1)'),
        [for (var n = 5; n >= 1; n--) BigInt.from(n)]);
    expect(await values('SELECT value FROM generate_series(1, 5, 2)'),
        [BigInt.one, BigInt.from(3), BigInt.from(5)]);
    expect(
        await values('SELECT value FROM generate_series(1, 1)'), [BigInt.one]);
    expect(await values('SELECT value FROM generate_series(1, 0)'), isEmpty);
    expect(await values('SELECT value FROM generate_series(5, 1)'), isEmpty);
    expect(await values('SELECT value FROM generate_series(1, 3, 0)'), isEmpty);
    expect(await values('SELECT value FROM generate_series(NULL, 2)'),
        [BigInt.zero, BigInt.one, BigInt.two]);
    expect(
        await values(
            'SELECT value FROM generate_series WHERE start = 2 AND stop = 4'),
        [BigInt.two, BigInt.from(3), BigInt.from(4)]);
    expect(
        await values(
            'SELECT value FROM generate_series(?, ?) WHERE value >= 2', [1, 3]),
        [BigInt.two, BigInt.from(3)]);
    final described = await database.query(
        'SELECT rowid, value, start, stop, step FROM generate_series(2, 4, 2)');
    expect(described.rows, [
      [BigInt.one, BigInt.two, BigInt.two, BigInt.from(4), BigInt.two],
      [BigInt.two, BigInt.from(4), BigInt.two, BigInt.from(4), BigInt.two]
    ]);
    expect(
        (await database.query('SELECT * FROM generate_series(8, 8)')).columns,
        ['value']);
    final max = BigInt.parse('9223372036854775807');
    expect(await values('SELECT value FROM generate_series(?, ?)', [max, max]),
        [max]);
    await expectLater(database.query('SELECT value FROM generate_series(1)'),
        throwsA(isA<SqlException>()));
    expect((await database.query('SELECT 1')).rows, [
      [BigInt.one]
    ]);
  });

  test('a closed cursor and a bad column do not poison the connection',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    final cursor = database.functions.virtualTables
        .find('generate_series')!
        .xOpen('direct');
    cursor.filter('direct', ['1', '1']);
    expect(() => cursor.column(9), throwsA(isA<SqlException>()));
    cursor.close();
    expect(() => cursor.next(), throwsA(isA<SqlException>()));
    expect(() => cursor.rowid, throwsA(isA<SqlException>()));
    expect(() => cursor.column(0), throwsA(isA<SqlException>()));
    expect((await database.query('SELECT 1')).rows, [
      [BigInt.one]
    ]);
    database.functions.virtualTables.register(_PoisonModule());
    await database.execute('BEGIN');
    await database.execute('CREATE TABLE kept(id INT)');
    await expectLater(database.execute('COMMIT'), throwsA(isA<SqlException>()));
    await expectLater(database.query('SELECT 1'), throwsStateError);
  });
}

final class _GateModule extends VirtualTableModule {
  final seen = <String>[];
  var yielded = 0;
  @override
  String get name => 'gate';
  @override
  List<String> get columns => const ['value'];
  @override
  void bestIndex(VirtualTableIndexPlan plan) {
    seen.clear();
    for (var index = 0; index < plan.constraints.length; index++) {
      final constraint = plan.constraints[index];
      if (constraint.column == 0 &&
          (constraint.operator == '=' || constraint.operator == '>')) {
        plan.use(index);
        seen.add('${constraint.operator}:${constraint.value}');
      }
    }
  }

  @override
  VirtualTableCursor xOpen(String table) => _GateCursor(this);
}

final class _GateCursor extends VirtualTableCursor {
  _GateCursor(this.module);
  final _GateModule module;
  static const all = ['a', 'b', 'c', 'd'];
  var rows = const <String>[];
  var index = 0;
  var closed = false;
  var used = const <VirtualTableConstraint>[];

  void _live() {
    if (closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void applyConstraints(List<VirtualTableConstraint> constraints) {
    _live();
    used = constraints;
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    rows = all.where((value) {
      for (final constraint in used) {
        if (constraint.operator == '=' && value != constraint.value) {
          return false;
        }
        if (constraint.operator == '>' &&
            value.compareTo('${constraint.value}') <= 0) {
          return false;
        }
      }
      return true;
    }).toList();
    module.yielded = rows.length;
    index = 0;
  }

  @override
  void next() {
    _live();
    if (index < rows.length) index++;
  }

  @override
  bool get eof {
    _live();
    return index >= rows.length;
  }

  @override
  Object? column(int column) {
    _live();
    if (eof || column != 0) {
      throw const SqlException('Virtual table column index out of range');
    }
    return rows[index];
  }

  @override
  BigInt get rowid {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    return BigInt.from(index + 1);
  }

  @override
  void close() {
    closed = true;
  }
}

final class _SecretModule extends VirtualTableModule {
  List<String> arguments = const [];
  @override
  String get name => 'secret';
  @override
  List<String> get columns => const ['value'];
  @override
  List<String> get hiddenColumns => const ['token'];
  @override
  VirtualTableCursor xOpen(String table) => _SecretCursor(this);
}

final class _SecretCursor extends VirtualTableCursor {
  _SecretCursor(this.module);
  final _SecretModule module;
  String? token;
  var index = 0;
  var closed = false;

  void _live() {
    if (closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    module.arguments = arguments;
    token = arguments.single;
    index = 0;
  }

  @override
  void next() {
    _live();
    index++;
  }

  @override
  bool get eof {
    _live();
    return index > 0;
  }

  @override
  Object? column(int column) {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    if (column == 0) return 'visible';
    if (column == 1) return token;
    throw const SqlException('Virtual table column index out of range');
  }

  @override
  BigInt get rowid => BigInt.one;
  @override
  void close() {
    closed = true;
  }
}

final class _EchoModule extends VirtualTableModule {
  @override
  String get name => 'echo';
  @override
  List<String> get columns => const ['value'];
  @override
  List<List<Object?>> read(String table, List<String> arguments) => [
        for (final argument in arguments) [argument]
      ];
}

final class _TxnModule extends VirtualTableModule {
  final log = <String>[];
  final rows = <String>[];
  @override
  String get name => 'txn';
  @override
  List<String> get columns => const ['value'];
  @override
  void xBegin() => log.add('begin');
  @override
  void xCreate(String table, List<String> arguments) {
    log.add('create');
    rows.add(arguments.single);
  }

  @override
  void xCommit() => log.add('commit');
  @override
  void xRollback() {
    log.add('rollback');
    rows.clear();
  }

  @override
  List<List<Object?>> read(String table, List<String> arguments) => [
        for (final row in rows) [row]
      ];
}

final class _PoisonModule extends VirtualTableModule {
  @override
  String get name => 'poison';
  @override
  List<String> get columns => const ['value'];
  @override
  void xCommit() => throw StateError('commit failed');
  @override
  List<List<Object?>> read(String table, List<String> arguments) => const [];
}
