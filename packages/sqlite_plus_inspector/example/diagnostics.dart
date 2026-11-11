import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_replay.dart';

Future<void> main() async {
  final db = await openInMemory();
  final inspector = SqlInspector();
  try {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,category INTEGER,n INTEGER CHECK(n>=0))');
    await db.execute('INSERT INTO items VALUES ${[
      for (var i = 1; i <= 100; i++) '($i,${i % 5},$i)'
    ].join(',')}');
    final original = db.exportImage();
    final report = await inspector.adviseIndex(
        db, 'SELECT id,n FROM items WHERE category=? ORDER BY n',
        parameters: [2]);
    final advice = report.advice;
    if (advice == null ||
        advice.afterBytes <= advice.beforeBytes ||
        db.exportImage().length != original.length) {
      throw StateError('Advisor snapshot');
    }
    print(
        'Candidate: ${advice.createSql}; planner selected=${advice.selectedByPlanner}; extra bytes=${advice.addedBytes}');

    // Explicit opt-in: artifact contains raw data, unlike normal Inspector logs.
    final recorder = await SqlReplayRecorder.start(db, inspector: inspector);
    await recorder.execute('BEGIN');
    await recorder.execute('UPDATE items SET n=n+? WHERE id=?', [5, 1]);
    await recorder.execute('COMMIT');
    await recorder.query('SELECT n FROM items WHERE id=?', [1]);
    final bytes = recorder.finish().toBytes();
    final replay = await SqlReplayArtifact.fromBytes(bytes).replay();
    if (!replay.matches) throw StateError('Diagnostic replay diverged');
    print(
        'Diagnostic replay assertions passed (${replay.executedStatements} statements).');
  } finally {
    inspector.close();
    await db.close();
  }
}
