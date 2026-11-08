import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'direct' : args.first;
  if (!['direct', 'disabled', 'enabled'].contains(mode))
    throw ArgumentError('mode');
  final count = args.length < 2 ? 1000 : int.parse(args[1]);
  final engine = await openInMemory();
  final inspector = SqlInspector(enabled: mode == 'enabled');
  final wrapped = inspector.database(engine);
  Future<QueryResult> query(String sql, List<Object?> params) =>
      mode == 'direct' ? engine.query(sql, params) : wrapped.query(sql, params);
  Future<MutationResult> execute(String sql, List<Object?> params) =>
      mode == 'direct'
          ? engine.execute(sql, params)
          : wrapped.execute(sql, params);
  try {
    await engine
        .execute('CREATE TABLE items(id INTEGER PRIMARY KEY,n INTEGER)');
    await engine.execute('INSERT INTO items VALUES ${[
      for (var i = 1; i <= count; i++) '($i,$i)'
    ].join(',')}');
    final clock = Stopwatch()..start();
    for (var i = 0; i < 200; i++) {
      final id = i % count + 1;
      final result = await query('SELECT n FROM items WHERE id=?', [id]);
      if (result.rows.single.single != BigInt.from(id))
        throw StateError('Point checksum');
    }
    for (var i = 0; i < 20; i++) {
      final result = await query(
          'SELECT id,n FROM items WHERE id>? ORDER BY id LIMIT 20',
          [count - 20]);
      if (result.rows.length != 20) throw StateError('Range checksum');
    }
    for (var i = 1; i <= 50; i++) {
      await execute('UPDATE items SET n=n+1 WHERE id=?', [i]);
    }
    clock.stop();
    final sum =
        (await engine.query('SELECT sum(n) FROM items')).rows.single.single;
    if (sum != BigInt.from(count * (count + 1) ~/ 2 + 50))
      throw StateError('Final checksum');
    final image = engine.exportImage();
    final report = inspector.snapshot();
    if (report.statementCount != (mode == 'enabled' ? 270 : 0))
      throw StateError('Observation count');
    print(jsonEncode({
      'mode': mode,
      'rows': count,
      'duration_us': clock.elapsedMicroseconds,
      'observed': report.statementCount,
      'retained_records': report.records.length,
      'retained_groups': report.groups.length,
      'reported_sql_us': report.totalDuration.inMicroseconds,
      'image_bytes': image.length,
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await engine.close();
    inspector.close();
  }
}
