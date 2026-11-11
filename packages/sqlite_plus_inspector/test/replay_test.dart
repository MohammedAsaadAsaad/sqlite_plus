import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_replay.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await openInMemory();
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER CHECK(n>=0),label TEXT,payload BLOB)');
    await db.execute("INSERT INTO t VALUES(1,10,'secret',X'0102')");
  });
  tearDown(() => db.close());
  test(
      'serial SQL, transactions, errors and returning replay on isolated image',
      () async {
    final inspector = SqlInspector();
    final recorder = await SqlReplayRecorder.start(db, inspector: inspector);
    await recorder.execute('BEGIN');
    await recorder.execute('UPDATE t SET n=n+? WHERE id=? RETURNING n', [2, 1]);
    await expectLater(
        recorder.execute('UPDATE t SET n=-1'), throwsA(isA<SqlException>()));
    await recorder.execute('COMMIT');
    await recorder.query('SELECT n,label,payload FROM t');
    final artifact = recorder.finish();
    final before = db.exportImage();
    final restored = SqlReplayArtifact.fromBytes(artifact.toBytes());
    expect(restored.statementCount, 5);
    expect((await restored.replay()).matches, isTrue);
    expect(db.exportImage(), before);
    expect(inspector.snapshot().records.any((r) => r.sql.contains('secret')),
        isFalse);
    inspector.close();
    await expectLater(recorder.query('SELECT 1'), throwsStateError);
  });
  test('64-bit bindings, BLOB snapshots, string semicolon/host words are data',
      () async {
    final recorder = await SqlReplayRecorder.start(db);
    final bytes = Uint8List.fromList([9, 8]);
    final future = recorder.execute('INSERT INTO t VALUES(?,?,?,?)',
        [BigInt.parse('9223372036854775807'), 1, 'PRAGMA; ATTACH', bytes]);
    bytes[0] = 99;
    await future;
    await recorder.query("SELECT ';', 'PRAGMA' FROM t ORDER BY id");
    final artifact = recorder.finish();
    expect((await artifact.replay()).matches, isTrue);
    final row = (await db.query('SELECT payload FROM t ORDER BY id DESC'))
        .rows
        .first
        .single as Uint8List;
    expect(row[0], 9);
  });
  test('source connection FK mode is captured', () async {
    await db.execute(
        'CREATE TABLE c(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES t(id))');
    await db.execute('PRAGMA foreign_keys=ON');
    final recorder = await SqlReplayRecorder.start(db);
    await expectLater(recorder.execute('INSERT INTO c VALUES(1,99)'),
        throwsA(isA<SqlException>()));
    expect((await recorder.finish().replay()).matches, isTrue);
  });
  test('unsupported SQL still delegates, visibly invalidates replay session',
      () async {
    final recorder = await SqlReplayRecorder.start(db);
    await recorder.execute('CREATE TABLE outside(id INTEGER)');
    expect(recorder.isComplete, isFalse);
    expect(recorder.finish, throwsStateError);
    expect(
        (await db.query("SELECT name FROM sqlite_schema WHERE name='outside'"))
            .rows,
        isNotEmpty);
  });
  test('capture budget does not swallow source outcomes', () async {
    final recorder = await SqlReplayRecorder.start(db,
        limits: const ReplayLimits(maxStatements: 1));
    await recorder.query('SELECT 1');
    await expectLater(recorder.execute('UPDATE missing SET n=1'),
        throwsA(isA<SqlException>()));
    expect(recorder.isComplete, isFalse);
    expect(recorder.finish, throwsStateError);
  });
  test('external bypass is detected by final logical state mismatch', () async {
    final recorder = await SqlReplayRecorder.start(db);
    await recorder.query('SELECT n FROM t');
    await db.execute('UPDATE t SET n=20');
    final report = await recorder.finish().replay();
    expect(report.matches, isFalse);
    expect(report.finalStateMatches, isFalse);
  });
  test('concurrent calls reject and open transactions prevent finish',
      () async {
    final recorder = await SqlReplayRecorder.start(db);
    final first = recorder.execute('BEGIN');
    await expectLater(recorder.query('SELECT 1'), throwsStateError);
    await first;
    expect(recorder.finish, throwsStateError);
    await recorder.execute('ROLLBACK');
    expect((await recorder.finish().replay()).matches, isTrue);
  });
  test('checksum/budget/forged host SQL are rejected on artifact decoding',
      () async {
    final recorder = await SqlReplayRecorder.start(db);
    await recorder.query('SELECT 1');
    final bytes = recorder.finish().toBytes();
    final malformed = Uint8List.fromList(bytes)..[10] = 0;
    expect(() => SqlReplayArtifact.fromBytes(malformed), throwsFormatException);
    expect(
        () => SqlReplayArtifact.fromBytes(bytes,
            limits: const ReplayLimits(maxArtifactBytes: 1024)),
        throwsFormatException);
    final raw = jsonDecode(utf8.decode(bytes)) as Map;
    final data = jsonDecode(raw['payload'] as String) as Map;
    (data['steps'] as List).first['sql'] = "ATTACH 'host.db' AS outside";
    raw['payload'] = jsonEncode(data);
    raw['sha256'] =
        sha256.convert(utf8.encode(raw['payload'] as String)).toString();
    expect(
        () => SqlReplayArtifact.fromBytes(
            Uint8List.fromList(utf8.encode(jsonEncode(raw)))),
        throwsFormatException);
  });
  test('mismatch in an outcome stops replay with a step index', () async {
    final recorder = await SqlReplayRecorder.start(db);
    await recorder.query('SELECT n FROM t');
    final bytes = recorder.finish().toBytes();
    final raw = jsonDecode(utf8.decode(bytes)) as Map;
    final data = jsonDecode(raw['payload'] as String) as Map;
    (data['steps'] as List).first['outcome'] = {'kind': 'ok', 'proof': 'wrong'};
    raw['payload'] = jsonEncode(data);
    raw['sha256'] =
        sha256.convert(utf8.encode(raw['payload'] as String)).toString();
    final report = await SqlReplayArtifact.fromBytes(
            Uint8List.fromList(utf8.encode(jsonEncode(raw))))
        .replay();
    expect(report.firstMismatch, 0);
    expect(report.executedStatements, 1);
  });
  test('logical replay survives different page packing in a larger image',
      () async {
    await db.execute('INSERT INTO t VALUES ${[
      for (var i = 2; i <= 1000; i++) "($i,$i,'row',NULL)"
    ].join(',')}');
    final recorder = await SqlReplayRecorder.start(db);
    await recorder.execute('BEGIN');
    for (var i = 1; i <= 20; i++) {
      await recorder.execute('UPDATE t SET n=n+1 WHERE id=?', [i]);
    }
    await recorder.execute('COMMIT');
    final artifact = recorder.finish();
    final report =
        await SqlReplayArtifact.fromBytes(artifact.toBytes()).replay();
    expect(report.firstMismatch, isNull);
    expect(report.finalStateMatches, isTrue);
  });
}
