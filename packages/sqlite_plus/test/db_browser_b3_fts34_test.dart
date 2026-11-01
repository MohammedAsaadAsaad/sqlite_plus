import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'rollback_pager_test.dart'
    show CrashController, ModelFile, SimulatedCrash;

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  if (!File(cli()).existsSync()) {
    test('pinned sqlite3 is not installed', () {
      markTestSkipped('pinned sqlite3 is not installed');
    });
    return;
  }

  late String tool;
  setUpAll(() async {
    tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
  });

  Future<String> pinned(List<String> statements) async {
    final result = await Process.run(tool, [':memory:', ...statements]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$statements');
    return result.stdout.toString().trim();
  }

  Future<String> engine(List<String> statements) async {
    final db = await MutableSqliteDatabase.create();
    try {
      String? last;
      for (var i = 0; i < statements.length; i++) {
        final sql = statements[i];
        final query =
            RegExp(r'^\s*(SELECT|PRAGMA|WITH)\b', caseSensitive: false)
                .hasMatch(sql);
        if (query) {
          final rows = await db.query(sql);
          if (i == statements.length - 1) {
            last = rows.rows
                .map((row) => row.map((cell) => cell ?? '').join('|'))
                .join('\n');
          }
        } else {
          await db.execute(sql);
        }
      }
      return last ?? '';
    } finally {
      await db.close();
    }
  }

  test('FTS3 and FTS4 writes match the pinned rows', () async {
    final cases = [
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('hello world')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts3(body)',
        "INSERT INTO f VALUES ('hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('')",
        'SELECT count(*) FROM f',
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('hello')",
        "DELETE FROM f WHERE f MATCH 'hello'",
        'SELECT count(*) FROM f',
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4(body)',
        "INSERT INTO f VALUES ('hello world')",
        "INSERT INTO f VALUES ('other')",
        "SELECT body FROM f WHERE f MATCH 'missing'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts3(body)',
        "INSERT INTO f VALUES ('Hello')",
        "SELECT body FROM f WHERE f MATCH 'hello'",
      ],
      [
        'CREATE VIRTUAL TABLE f USING fts4()',
        "INSERT INTO f VALUES ('hello')",
        "SELECT content FROM f WHERE f MATCH 'hello'",
      ],
    ];
    for (final statements in cases) {
      expect(await engine(statements), await pinned(statements),
          reason: statements.join('; '));
    }
  });

  test('negative FTS3 and FTS4 statements match the pin errors', () async {
    final missing = await Process.run(tool, [
      ':memory:',
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      'SELECT body FROM missing',
    ]);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such table: missing'));
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE f USING fts4(body)');
    await expectLater(
        db.query('SELECT body FROM missing'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'no such table: missing')));
    await expectLater(db.execute("INSERT INTO missing VALUES ('x')"),
        throwsA(isA<SqlException>()));
    final mismatch = await Process.run(tool, [
      ':memory:',
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      "INSERT INTO f VALUES('a','b')",
    ]);
    expect(mismatch.exitCode, isNonZero);
    expect(mismatch.stderr.toString(),
        contains('table f has 1 columns but 2 values were supplied'));
    await expectLater(db.execute("INSERT INTO f VALUES('a','b')"),
        throwsA(isA<SqlException>()));
  });

  test('boundary empty match and a second row stay distinct', () async {
    final statements = [
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      "INSERT INTO f VALUES ('')",
      "INSERT INTO f VALUES ('hello')",
      "SELECT count(*) FROM f WHERE f MATCH 'hello'",
    ];
    expect(await engine(statements), await pinned(statements));
    final both = [
      'CREATE VIRTUAL TABLE f USING fts3(body)',
      "INSERT INTO f VALUES ('hello')",
      "INSERT INTO f VALUES ('hello world')",
      'SELECT count(*) FROM f',
    ];
    expect(await engine(both), await pinned(both));
  });

  test('exported FTS3 and FTS4 images pass the pinned integrity check',
      () async {
    final cases = <(List<String>, String, String)>[
      (
        [
          'CREATE VIRTUAL TABLE f USING fts4(body)',
          "INSERT INTO f VALUES ('hello world')",
        ],
        "PRAGMA integrity_check; SELECT body FROM f WHERE f MATCH 'hello';",
        'ok\nhello world'
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts3(body)',
          "INSERT INTO f VALUES ('hello')",
        ],
        "PRAGMA integrity_check; SELECT body FROM f WHERE f MATCH 'hello';",
        'ok\nhello'
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts4(body)',
          "INSERT INTO f VALUES ('')",
        ],
        'PRAGMA integrity_check; SELECT count(*) FROM f;',
        'ok\n1'
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts4(body)',
          "INSERT INTO f VALUES ('hello')",
          "DELETE FROM f WHERE f MATCH 'hello'",
        ],
        'PRAGMA integrity_check; SELECT count(*) FROM f;',
        'ok\n0'
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts4()',
          "INSERT INTO f VALUES ('hello')",
        ],
        "PRAGMA integrity_check; SELECT content FROM f WHERE f MATCH 'hello';",
        'ok\nhello'
      ),
      (
        [
          'CREATE VIRTUAL TABLE f USING fts4(title, body)',
          "INSERT INTO f(docid, title, body) VALUES (5, 'Hello World', 'sqlite hello')",
          "INSERT INTO f(docid, title, body) VALUES (9, 'other', NULL)",
        ],
        "PRAGMA integrity_check; SELECT title FROM f WHERE f MATCH 'hello';"
            " SELECT title FROM f WHERE f MATCH 'other';",
        'ok\nHello World\nother'
      ),
    ];
    for (final entry in cases) {
      final image = await _export(entry.$1);
      expect(await _pinFile(tool, image, entry.$2), entry.$3,
          reason: entry.$1.join('; '));
    }
  });

  test('a damaged FTS4 root fails the pinned integrity check', () async {
    final image = await _export([
      'CREATE VIRTUAL TABLE f USING fts4(body)',
      "INSERT INTO f VALUES ('hello world')",
    ]);
    final bytes = Uint8List.fromList(image);
    const needle = [0x00, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f];
    final at = _findBytes(bytes, needle);
    expect(at, greaterThanOrEqualTo(0));
    bytes[at + needle.length - 1] = 0x78;
    final file = File('${Directory.systemTemp.path}/sqlite_plus_fts4_bad.db');
    await file.writeAsBytes(bytes, flush: true);
    final damaged =
        await Process.run(tool, [file.path, 'PRAGMA integrity_check;']);
    expect(damaged.exitCode, 0);
    expect(damaged.stdout.toString().trim(),
        'malformed inverted index for FTS4 table main.f');
    final db = await MutableSqliteDatabase.fromImage(bytes);
    addTearDown(db.close);
    expect((await db.query('SELECT body FROM f')).rows, [
      ['hello world']
    ]);
  });

  test('a crash during an FTS4 insert recovers a pinned-valid image', () async {
    final seed = await MutableSqliteDatabase.create();
    await seed.execute('CREATE VIRTUAL TABLE f USING fts4(body)');
    final original = seed.exportImage();
    await seed.close();
    final baseline = CrashController();
    final baselinePager = await RollbackJournalPager.open(
        ModelFile(original, baseline), ModelFile(Uint8List(0), baseline));
    final writer = await MutableSqliteDatabase.fromJournalPager(baselinePager);
    await writer.execute("INSERT INTO f VALUES ('hello world')");
    final operations = baseline.operations;
    await writer.close();
    expect(operations, greaterThan(0));
    var sawOld = false;
    var sawNew = false;
    for (var point = 1; point <= operations; point++) {
      final faults = CrashController()..crashAt = point;
      final database = ModelFile(original, faults);
      final log = ModelFile(Uint8List(0), faults);
      final opened = await RollbackJournalPager.open(database, log);
      final db = await MutableSqliteDatabase.fromJournalPager(opened);
      await expectLater(db.execute("INSERT INTO f VALUES ('hello world')"),
          throwsA(isA<SimulatedCrash>()),
          reason: 'operation $point');
      database.crash();
      log.crash();
      faults.crashAt = null;
      final recovered = await RollbackJournalPager.open(database, log);
      final image = await recovered.readImage();
      final reader = await MutableSqliteDatabase.fromImage(image);
      expect(
          (await reader.query('PRAGMA integrity_check')).rows,
          [
            ['ok']
          ],
          reason: 'operation $point');
      final rows = (await reader.query('SELECT body FROM f')).rows;
      final oldRows = rows.isEmpty;
      final newRows = rows.length == 1 && rows.single.single == 'hello world';
      expect(oldRows || newRows, isTrue, reason: 'operation $point $rows');
      final pinned = await _pinFile(tool, image,
          "PRAGMA integrity_check; SELECT count(*) FROM f WHERE f MATCH 'hello';");
      expect(pinned, oldRows ? 'ok\n0' : 'ok\n1', reason: 'operation $point');
      sawOld = sawOld || oldRows;
      sawNew = sawNew || newRows;
      await reader.close();
      await recovered.close();
    }
    expect(sawOld, isTrue);
    expect(sawNew, isTrue);
  });

  test('contentless FTS4 writes match the pinned rows', () async {
    expect(
        await engine([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          "SELECT rowid FROM f WHERE f MATCH 'hello'",
        ]),
        await pinned([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          "SELECT rowid FROM f WHERE f MATCH 'hello'",
        ]));
    expect(
        await engine([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          "INSERT INTO f(docid, body) VALUES(8, 'other text')",
          "SELECT rowid FROM f WHERE f MATCH 'other'",
        ]),
        '8');
    expect(
        await engine([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          "SELECT rowid FROM f WHERE f MATCH 'missing'",
        ]),
        '');
    expect(
        await engine([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          'PRAGMA integrity_check',
        ]),
        await pinned([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          'PRAGMA integrity_check',
        ]));

    Future<String> engineError(List<String> statements) async {
      try {
        await engine(statements);
      } on SqlException catch (error) {
        return error.message;
      }
      fail('expected SQL error: $statements');
    }

    Future<String> pinError(String sql) async {
      final result = await Process.run(tool, [':memory:', sql]);
      expect(result.exitCode, isNot(0));
      final text = result.stderr.toString().trim();
      final marker = text.lastIndexOf(':');
      return marker < 0 ? text : text.substring(marker + 1).trim();
    }

    const setup = "CREATE VIRTUAL TABLE f USING fts4(body, content=''); "
        "INSERT INTO f(docid, body) VALUES(7, 'hello world'); ";
    expect(
        await engineError([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          'SELECT rowid FROM f',
        ]),
        await pinError('${setup}SELECT rowid FROM f'));
    expect(
        await engineError([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          "SELECT body FROM f WHERE f MATCH 'hello'",
        ]),
        await pinError("${setup}SELECT body FROM f WHERE f MATCH 'hello'"));
    expect(
        await engineError([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
          'DELETE FROM f WHERE docid=7',
        ]),
        await pinError('${setup}DELETE FROM f WHERE docid=7'));
    expect(
        await engineError([
          "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
          "INSERT INTO f VALUES('hello')",
        ]),
        await pinError(
            "CREATE VIRTUAL TABLE f USING fts4(body, content=''); INSERT INTO f VALUES('hello')"));

    final file =
        File('${Directory.systemTemp.path}/sqlite_plus_fts4_contentless.db');
    if (file.existsSync()) file.deleteSync();
    final created = await Process.run(tool, [
      file.path,
      "CREATE VIRTUAL TABLE f USING fts4(body, content='')",
      "INSERT INTO f(docid, body) VALUES(7, 'hello world')",
    ]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final native =
        await MutableSqliteDatabase.fromImage(await file.readAsBytes());
    addTearDown(native.close);
    expect(
        (await native.query("SELECT rowid FROM f WHERE f MATCH 'hello'")).rows,
        [
          [BigInt.from(7)]
        ]);
    await native.execute("INSERT INTO f(docid, body) VALUES(9, 'later')");
    expect(
        (await native.query("SELECT rowid FROM f WHERE f MATCH 'later'")).rows,
        [
          [BigInt.from(9)]
        ]);
  });

  test('regression FTS5 writes and a native FTS4 insert stay readable',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE u USING fts5(body)');
    await db.execute("INSERT INTO u VALUES ('kept')");
    expect((await db.query("SELECT body FROM u WHERE u MATCH 'kept'")).rows, [
      ['kept']
    ]);
    final file = File('${Directory.systemTemp.path}/sqlite_plus_fts4_guard.db');
    if (file.existsSync()) file.deleteSync();
    final created = await Process.run(tool, [
      file.path,
      'CREATE VIRTUAL TABLE t USING fts4(title, body)',
      "INSERT INTO t(title, body) VALUES('hello world', 'sqlite')",
    ]);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final native =
        await MutableSqliteDatabase.fromImage(await file.readAsBytes());
    addTearDown(native.close);
    expect(
        (await native.query("SELECT title FROM t WHERE t MATCH 'hello'"))
            .rows
            .single
            .single,
        'hello world');
    await native.execute("INSERT INTO t(title, body) VALUES('more', 'text')");
    expect(
        await _pinFile(
            tool,
            native.exportImage(),
            "PRAGMA integrity_check; SELECT title FROM t WHERE t MATCH 'hello';"
            " SELECT body FROM t WHERE t MATCH 'text';"),
        'ok\nhello world\ntext');
  });
}

Future<Uint8List> _export(List<String> statements) async {
  final db = await MutableSqliteDatabase.create();
  try {
    for (final sql in statements) {
      await db.execute(sql);
    }
    return db.exportImage();
  } finally {
    await db.close();
  }
}

Future<String> _pinFile(String tool, Uint8List image, String sql) async {
  final file =
      File('${Directory.systemTemp.path}/sqlite_plus_fts34_${image.length}.db');
  await file.writeAsBytes(image, flush: true);
  final result = await Process.run(tool, [file.path, sql]);
  expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
  return result.stdout.toString().trim();
}

int _findBytes(Uint8List bytes, List<int> needle) {
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var found = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        found = false;
        break;
      }
    }
    if (found) return i;
  }
  return -1;
}
