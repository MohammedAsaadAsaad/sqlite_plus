import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  test(
      'external-content index initial and incremental snapshots cross-open in pinned SQLite',
      () async {
    final pin =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
    expect(pin.exitCode, 0);
    expect(pin.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    final dir = await Directory.systemTemp.createTemp('search-native-');
    addTearDown(() => dir.delete(recursive: true));
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db.execute(
        'INSERT INTO docs VALUES (?,?), (?,?)', [1, 'حَلِيب milk', 2, 'tea']);
    final search = await SqlitePlusSearch.open(database: db);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
    Future<void> compare(String query) async {
      final file = File('${dir.path}/snapshot.db');
      await file.writeAsBytes(db.exportImage());
      final native = await Process.run(cli, [
        file.path,
        "PRAGMA integrity_check; INSERT INTO _sps_1_fts(_sps_1_fts,rank) VALUES('integrity-check',1); SELECT source_key FROM _sps_1_keys WHERE id IN (SELECT rowid FROM _sps_1_fts WHERE _sps_1_fts MATCH '$query') ORDER BY source_key;"
      ]);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final expected = (await search.search(query, table: 'docs'))
          .hits
          .map((h) => h.documentId)
          .toList()
        ..sort();
      expect(native.stdout.toString().trim().split('\n'), ['ok', ...expected]);
    }

    await compare('حليب');
    await db.execute("UPDATE docs SET body='حليب tea' WHERE id=1");
    await db.execute("INSERT INTO docs VALUES (3,'milk')");
    await search.synchronize(table: 'docs');
    await compare('milk');
    await compare('tea');
  },
      skip: !File(cli).existsSync()
          ? 'Pinned native SQLite is optional development tooling, not installed'
          : false);
}
