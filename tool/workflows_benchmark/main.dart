import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_replay.dart';

final class Item {
  Item(this.id, this.name, this.n);
  final BigInt id;
  String? name;
  int n;
}

final id = Column<Item, BigInt>(
    property: 'id', codec: Codecs.bigInt, keyOrder: 0, read: (x) => x.id);
final name = Column<Item, String?>(
    property: 'name',
    codec: Codecs.nullable(Codecs.text),
    read: (x) => x.name,
    write: (x, v) => x.name = v);
final n = Column<Item, int>(
    property: 'n',
    codec: Codecs.integer,
    read: (x) => x.n,
    write: (x, v) => x.n = v);
final type = EntityType<Item>(
    tableName: 'items',
    columns: [id, name, n],
    create: (r) => Item(r.read(id), r.read(name), r.read(n)));

Future<void> main(List<String> args) async {
  final mode = args[0], count = int.parse(args[1]);
  final db = await openInMemory();
  final inspector = SqlInspector(enabled: false);
  final phases = <String, int>{};
  final sizes = <String, int>{};
  try {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,n INTEGER,grp INTEGER)');
    await db.execute('INSERT INTO items VALUES ${[
      for (var i = 1; i <= count; i++) "($i,'item$i',$i,${i % 5})"
    ].join(',')}');
    final before = db.exportImage();
    sizes['base_bytes'] = before.length;
    final clock = Stopwatch()..start();
    if (mode == 'import') {
      final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
      try {
        final plan = await context.set(type).prepareImport(
            [for (var i = 1; i <= count; i++) Item(BigInt.from(i), '', i + 1)],
            conflictOn: [id],
            update: [name, n],
            emptyValues: OrmImportEmptyValues.keepExisting);
        phases['prepare_us'] = clock.elapsedMicroseconds;
        clock
          ..reset()
          ..start();
        final result = await plan.apply();
        phases['apply_us'] = clock.elapsedMicroseconds;
        if (result.affectedRows != count) throw StateError('Import count');
      } finally {
        await context.close();
      }
    } else if (mode == 'preview') {
      final preview =
          await SqlitePlusBranches(database: db, sourceId: 'benchmark').preview(
              (draft) => draft.execute('UPDATE items SET n=n+1 WHERE id<=10'));
      phases['preview_us'] = clock.elapsedMicroseconds;
      if (preview.changes.length != 10 ||
          sha256.convert(db.exportImage()) != sha256.convert(before)) {
        throw StateError('Preview isolation');
      }
      clock
        ..reset()
        ..start();
      await preview.merge();
      phases['merge_us'] = clock.elapsedMicroseconds;
      await preview.close();
    } else if (mode == 'advisor') {
      final report = await inspector.adviseIndex(
          db, 'SELECT id,n FROM items WHERE grp=? ORDER BY n',
          parameters: [2]);
      phases['advice_us'] = clock.elapsedMicroseconds;
      final advice = report.advice!;
      sizes['index_bytes'] = advice.addedBytes;
      phases['index_build_us'] = advice.buildDuration.inMicroseconds;
      if (sha256.convert(db.exportImage()) != sha256.convert(before)) {
        throw StateError('Advisor isolation');
      }
    } else if (mode == 'replay') {
      final recorder = await SqlReplayRecorder.start(db);
      await recorder.execute('BEGIN');
      for (var i = 1; i <= 20; i++) {
        await recorder.execute('UPDATE items SET n=n+1 WHERE id=?', [i]);
      }
      await recorder.execute('COMMIT');
      await recorder.query('SELECT n FROM items ORDER BY id');
      final bytes = recorder.finish().toBytes();
      phases['record_us'] = clock.elapsedMicroseconds;
      sizes['artifact_bytes'] = bytes.length;
      clock
        ..reset()
        ..start();
      final replay = await SqlReplayArtifact.fromBytes(bytes).replay();
      phases['replay_us'] = clock.elapsedMicroseconds;
      if (!replay.matches)
        throw StateError(
            'Replay equality step=${replay.firstMismatch} final=${replay.finalStateMatches}');
    } else {
      throw ArgumentError('mode');
    }
    final rows =
        (await db.query('SELECT id,name,n FROM items ORDER BY id')).rows;
    for (var i = 0; i < count; i++) {
      final key = i + 1;
      final changed = mode == 'import' ||
          mode == 'preview' && key <= 10 ||
          mode == 'replay' && key <= 20;
      if (rows[i][0] != BigInt.from(key) ||
          rows[i][1] != 'item$key' ||
          rows[i][2] != BigInt.from(key + (changed ? 1 : 0))) {
        throw StateError('Final row');
      }
    }
    final image = db.exportImage();
    sizes['final_bytes'] = image.length;
    final logical = jsonEncode(
        rows.map((r) => r.map((v) => v.toString()).toList()).toList());
    print(jsonEncode({
      'mode': mode,
      'rows': count,
      ...phases,
      ...sizes,
      'logical_sha256': sha256.convert(utf8.encode(logical)).toString(),
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    inspector.close();
    await db.close();
  }
}
