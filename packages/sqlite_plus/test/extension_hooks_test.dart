import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('a registered tokenizer is used and a built-in name stays fixed',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    expect(
        () => database.functions.tokenizers
            .register('unicode61', (options) => MarkTokenizer(options)),
        throwsArgumentError);
    database.functions.tokenizers
        .register('mark', (options) => MarkTokenizer(options));
    database.functions.tokenizers
        .register('mark', (options) => MarkTokenizer(options));
    await database.execute(
        "CREATE VIRTUAL TABLE docs USING fts5(body, tokenize = 'mark')");
    await database
        .execute('INSERT INTO docs(body) VALUES (?), (?)', ['Hello', 'other']);
    final found =
        await database.query("SELECT body FROM docs WHERE docs MATCH 'h'");
    expect(found.rows, [
      ['Hello']
    ]);
    final missed =
        await database.query("SELECT body FROM docs WHERE docs MATCH 'z'");
    expect(missed.rows, isEmpty);
    await expectLater(
        database.execute(
            "CREATE VIRTUAL TABLE bad USING fts5(body, tokenize = 'mark extra 1')"),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'error in tokenizer constructor')));
    await expectLater(
        database.execute(
            "CREATE VIRTUAL TABLE missing USING fts5(body, tokenize = 'nope')"),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'no such tokenizer: nope')));
  });

  test('a row-storing module round-trips, reopens, and drops its shadow',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    database.functions.virtualTables.register(EchoModule());
    await database.execute('CREATE VIRTUAL TABLE notes USING echo()');
    await database
        .execute('INSERT INTO notes(body) VALUES (?), (?)', ['kept', 'other']);
    final rows = await database.query('SELECT rowid, body FROM notes');
    expect(rows.rows, [
      [BigInt.one, 'kept'],
      [BigInt.two, 'other']
    ]);
    await database.execute('DELETE FROM notes WHERE rowid = 2');
    final image = database.exportImage();
    final reopened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(reopened.close);
    reopened.functions.virtualTables.register(EchoModule());
    final again = await reopened.query('SELECT body FROM notes');
    expect(again.rows, [
      ['kept']
    ]);
    await reopened.execute('DROP TABLE notes');
    await expectLater(reopened.query('SELECT * FROM notes_vec'),
        throwsA(isA<SqlException>()));
    await expectLater(
        reopened.execute('CREATE VIRTUAL TABLE bare USING absent()'),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'No such module: absent')));
  });
}

final class MarkTokenizer extends FtsTokenizer {
  MarkTokenizer(List<String> options) {
    if (options.isNotEmpty) {
      throw const SqlException('error in tokenizer constructor');
    }
  }

  @override
  String get name => 'mark';

  @override
  List<FtsToken> tokenize(String text) {
    final bytes = utf8Bytes(text);
    final tokens = <FtsToken>[];
    var index = 0;
    while (index < bytes.length) {
      while (index < bytes.length && bytes[index] <= 32) {
        index++;
      }
      if (index == bytes.length) break;
      final start = index;
      while (index < bytes.length && bytes[index] > 32) {
        index++;
      }
      final unit = bytes[start];
      final folded = unit >= 65 && unit <= 90 ? unit + 32 : unit;
      tokens.add(FtsToken(String.fromCharCode(folded), start, start + 1));
    }
    return tokens;
  }
}

Uint8List utf8Bytes(String text) {
  final units = text.codeUnits;
  final bytes = <int>[];
  for (final unit in units) {
    if (unit < 128) {
      bytes.add(unit);
    } else {
      throw ArgumentError('The mark tokenizer test uses ASCII');
    }
  }
  return Uint8List.fromList(bytes);
}

final class EchoModule extends VirtualTableModule {
  @override
  String get name => 'echo';

  @override
  List<String> get columns => const ['body'];

  @override
  bool get storesRows => true;

  @override
  List<({String name, String type})> shadowFields(
          String table, List<String> arguments) =>
      const [(name: 'body', type: 'TEXT')];

  @override
  List<String> shadowNames(String table, List<String> arguments) =>
      [shadowName(table, arguments)];

  @override
  List<String> ownedShadows(String table, List<String> arguments) =>
      shadowNames(table, arguments);

  @override
  VirtualTableCursor xOpen(String table) => _EchoCursor();
}

final class _EchoCursor extends VirtualTableCursor {
  var _closed = false;
  var _index = 0;
  List<(BigInt, String?)> _rows = const [];

  void _live() {
    if (_closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    final shadow = SearchSnapshot.current.table('${table}_vec');
    _rows = [
      if (shadow != null)
        for (final row in shadow.rows)
          (row.rowId, shadow.value(row, 'body') as String?)
    ];
    _index = 0;
  }

  @override
  void next() {
    _live();
    if (_index < _rows.length) _index++;
  }

  @override
  bool get eof {
    _live();
    return _index >= _rows.length;
  }

  @override
  Object? column(int index) {
    _live();
    if (eof || index != 0) {
      throw const SqlException('Virtual table column index out of range');
    }
    return _rows[_index].$2;
  }

  @override
  BigInt get rowid {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    return _rows[_index].$1;
  }

  @override
  void close() {
    _closed = true;
    _rows = const [];
  }
}
