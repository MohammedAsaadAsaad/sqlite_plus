@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late MutableSqliteDatabase db;
  late SqlitePlusBranches manager;
  late SqliteBranch branch;
  late String path;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('branches_');
    path = '${dir.path}/draft';
    db = await openInMemory();
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('INSERT INTO t VALUES(1,10)');
    manager = SqlitePlusBranches(database: db, sourceId: 'catalog');
    branch = await manager.create(name: 'draft');
  });
  tearDown(() async {
    await branch.close();
    await db.close();
    await dir.delete(recursive: true);
  });

  test('save reopen, lease, two slots, delete tombstone and close', () async {
    final store = await FileBranchStore.open(path);
    expect(await store.readArchive(), isNull);
    await expectLater(
        FileBranchStore.open(path), throwsA(isA<BranchException>()));
    await branch.database.execute('UPDATE t SET n=20');
    await store.save(branch);
    await store.close();
    final next = await FileBranchStore.open(path);
    final restored = await manager.restore((await next.readArchive())!);
    expect(
        (await restored.database.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(20));
    await next.delete();
    expect(await next.readArchive(), isNull);
    await restored.close();
    await next.close();
    final reopened = await FileBranchStore.open(path);
    expect(await reopened.readArchive(), isNull);
    await reopened.close();
    await expectLater(next.readArchive(), throwsA(isA<BranchException>()));
  });

  test('torn newest checkpoint falls back; corrupt both fail closed', () async {
    final store = await FileBranchStore.open(path);
    await branch.database.execute('UPDATE t SET n=20');
    await store.save(branch);
    await branch.database.execute('UPDATE t SET n=30');
    await store.save(branch);
    // Generation 2 goes into slot zero; emulate interruption mid-write.
    await File('$path.0').writeAsString('{"payload":', flush: true);
    final restored = await manager.restore((await store.readArchive())!);
    expect(
        (await restored.database.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(20));
    await restored.close();
    // Repair uses the other slot, keeping the valid prior checkpoint intact.
    await store.save(branch);
    final latest = await manager.restore((await store.readArchive())!);
    expect((await latest.database.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(30));
    await latest.close();
    await File('$path.0').writeAsString('bad');
    await File('$path.1').writeAsString('bad');
    await expectLater(store.readArchive(), throwsA(isA<BranchException>()));
    await store.close();
  });

  test(
      'process exit without close retains flushed checkpoint and releases lease',
      () async {
    final script = File('${dir.path}/child.dart');
    await script.writeAsString('''
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch_io.dart';
Future<void> main(List<String> args) async {
  final db=await openInMemory();
  await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
  await db.execute('INSERT INTO t VALUES(1,42)');
  final b=await SqlitePlusBranches(database:db,sourceId:'catalog').create(name:'child');
  final s=await FileBranchStore.open(args.single);
  await s.save(b);
  exit(0);
}
''');
    final config = Platform.packageConfig!;
    final result = await Process.run(
        Platform.resolvedExecutable, ['--packages=$config', script.path, path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final store = await FileBranchStore.open(path);
    final restored = await manager.restore((await store.readArchive())!);
    expect(
        (await restored.database.query('SELECT n FROM t')).rows.single.single,
        BigInt.from(42));
    await restored.close();
    await store.close();
  });

  test('slot checksum and budget reject malformed checkpoint', () async {
    final store = await FileBranchStore.open(path);
    await store.save(branch);
    final slot = File('$path.1');
    final json = jsonDecode(await slot.readAsString()) as Map;
    json['sha256'] = 'bad';
    await slot.writeAsString(jsonEncode(json));
    await expectLater(store.readArchive(), throwsA(isA<BranchException>()));
    await store.close();
    final small = await FileBranchStore.open(path, maxArchiveBytes: 1);
    await expectLater(small.save(branch), throwsA(isA<BranchException>()));
    await small.close();
  });
}
