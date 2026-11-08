import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';
import 'package:test/test.dart';

final class FaultPager implements ImagePager {
  FaultPager(this.image);
  Uint8List image;
  bool armed = false, afterCommit = false;
  @override
  Future<Uint8List> readImage() async => Uint8List.fromList(image);
  @override
  Future<void> commitImage(Uint8List next) async {
    if (armed && !afterCommit) {
      armed = false;
      throw StateError('before commit');
    }
    image = Uint8List.fromList(next);
    if (armed) {
      armed = false;
      throw StateError('commit acknowledged late');
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  for (final after in [false, true]) {
    test(
        'recover uncertain commit afterCommit=$after without double application',
        () async {
      final initial = await openInMemory();
      await initial.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
      await initial.execute('INSERT INTO t VALUES(1,10)');
      final pager = FaultPager(initial.exportImage());
      await initial.close();
      final db = await MutableSqliteDatabase.fromImagePager(pager);
      final manager = SqlitePlusBranches(database: db, sourceId: 'catalog');
      final branch = await manager.create(name: 'draft');
      await branch.database.execute('UPDATE t SET n=20');
      final archive = await branch.exportArchive();
      pager.afterCommit = after;
      pager.armed = true;
      await expectLater(branch.merge(), throwsA(anything));
      await expectLater(manager.create(name: 'unsafe'), throwsA(anything));
      // Recover from the image retained at the pager's atomic commit boundary.
      final recovered = await MutableSqliteDatabase.fromImage(pager.image);
      final reopened =
          SqlitePlusBranches(database: recovered, sourceId: 'catalog');
      final restored = await reopened.restore(archive);
      final result = await restored.merge();
      expect(result.alreadyMerged, after);
      expect((await recovered.query('SELECT n FROM t')).rows.single.single,
          BigInt.from(20));
      expect(
          (await recovered.query('SELECT COUNT(*) FROM _spb_merges'))
              .rows
              .single
              .single,
          BigInt.one);
      await restored.close();
      await recovered.close();
      await branch.close();
      try {
        await db.close();
      } catch (_) {}
    });
  }
}
