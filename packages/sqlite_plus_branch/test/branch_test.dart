import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase main;
  late SqlitePlusBranches branches;
  final handles = <SqliteBranch>[];
  Future<SqliteBranch> create() async {
    final b = await branches.create(name: 'prices');
    handles.add(b);
    return b;
  }

  setUp(() async {
    main = await openInMemory();
    await main.execute(
        'CREATE TABLE products(sku TEXT PRIMARY KEY NOT NULL,price INTEGER NOT NULL CHECK(price>=0),stock INTEGER NOT NULL,payload BLOB)');
    await main.execute("INSERT INTO products VALUES('a',500,100,X'0102')");
    branches = SqlitePlusBranches(database: main, sourceId: 'catalog');
  });
  tearDown(() async {
    for (final b in handles) {
      try {
        await b.close();
      } catch (_) {}
    }
    handles.clear();
    await main.close();
  });
  Future<List<Object?>> row(MutableSqliteDatabase db) async =>
      (await db.query("SELECT price,stock FROM products WHERE sku='a'"))
          .rows
          .single;

  test(
      'isolated full-copy snapshot, field merge preserves independent main edit',
      () async {
    final before = main.exportImage();
    final b = await create();
    expect(main.exportImage(), before);
    await b.database.execute("UPDATE products SET price=550 WHERE sku='a'");
    await main.execute("UPDATE products SET stock=97 WHERE sku='a'");
    expect(await row(b.database), [BigInt.from(550), BigInt.from(100)]);
    expect(await row(main), [BigInt.from(500), BigInt.from(97)]);
    final diff = await b.diff();
    expect(diff.single.changedColumns, ['price']);
    final preview = await b.previewMerge();
    expect(preview.conflicts, isEmpty);
    expect((await b.merge(preview: preview)).appliedRows, 1);
    expect(await row(main), [BigInt.from(550), BigInt.from(97)]);
    expect((await b.merge()).alreadyMerged, isTrue);
  });

  for (final choice in ['main', 'branch', 'custom']) {
    test('same-field conflict resolves $choice explicitly', () async {
      final b = await create();
      await b.database.execute('UPDATE products SET price=550');
      await main.execute('UPDATE products SET price=520');
      final preview = await b.previewMerge();
      final conflict = preview.conflicts.single;
      expect(conflict.kind, 'update-update');
      expect(conflict.column, 'price');
      expect([conflict.baseValue, conflict.mainValue, conflict.branchValue],
          [BigInt.from(500), BigInt.from(520), BigInt.from(550)]);
      await expectLater(b.merge(), throwsA(isA<BranchConflictException>()));
      final resolution = choice == 'main'
          ? const BranchResolution.useMain()
          : choice == 'branch'
              ? const BranchResolution.useBranch()
              : BranchResolution.value(530);
      await b.merge(preview: preview, resolutions: {conflict.id: resolution});
      expect(
          (await row(main)).first,
          BigInt.from(choice == 'main'
              ? 520
              : choice == 'branch'
                  ? 550
                  : 530));
    });
  }

  test(
      'stale main/working previews and unknown resolutions fail without writes',
      () async {
    final b = await create();
    await b.database.execute('UPDATE products SET price=550');
    final preview = await b.previewMerge();
    await main.execute('UPDATE products SET stock=99');
    final before = main.exportImage();
    await expectLater(
        b.merge(preview: preview), throwsA(isA<BranchException>()));
    expect(main.exportImage(), before);
    final next = await b.previewMerge();
    await b.database.execute('UPDATE products SET price=551');
    await expectLater(b.merge(preview: next), throwsA(isA<BranchException>()));
    await expectLater(
        b.merge(resolutions: {'unknown': const BranchResolution.useMain()}),
        throwsA(isA<BranchException>()));
  });

  test('insert delete net diff and reverted updates', () async {
    final b = await create();
    await b.database.execute('UPDATE products SET price=501');
    await b.database.execute('UPDATE products SET price=500');
    expect(await b.diff(), isEmpty);
    await b.database.execute("DELETE FROM products WHERE sku='a'");
    await b.database.execute("INSERT INTO products VALUES('b',1,2,NULL)");
    expect((await b.diff()).map((d) => d.kind).toSet(), {'delete', 'insert'});
    await b.merge();
    expect((await main.query('SELECT sku FROM products')).rows, [
      ['b']
    ]);
  });

  for (final scenario in ['insert-insert', 'delete-update', 'update-delete']) {
    test('row conflict $scenario can choose branch', () async {
      final b = await create();
      if (scenario == 'insert-insert') {
        await b.database.execute("INSERT INTO products VALUES('b',1,1,NULL)");
        await main.execute("INSERT INTO products VALUES('b',2,2,NULL)");
      } else if (scenario == 'delete-update') {
        await b.database.execute('DELETE FROM products');
        await main.execute('UPDATE products SET price=520');
      } else {
        await b.database.execute('UPDATE products SET price=550');
        await main.execute('DELETE FROM products');
      }
      final preview = await b.previewMerge();
      final c = preview.conflicts.single;
      expect(c.kind, scenario);
      await expectLater(
          b.merge(resolutions: {c.id: BranchResolution.value(null)}),
          throwsA(isA<BranchException>()));
      await b.merge(resolutions: {c.id: const BranchResolution.useBranch()});
      if (scenario == 'delete-update') {
        expect((await main.query('SELECT * FROM products')).rows, isEmpty);
      }
      if (scenario == 'update-delete') {
        expect((await row(main)).first, BigInt.from(550));
      }
      if (scenario == 'insert-insert') {
        expect(
            (await main.query("SELECT price FROM products WHERE sku='b'"))
                .rows
                .single
                .single,
            BigInt.one);
      }
    });
  }

  for (final scenario in ['insert-insert', 'delete-update', 'update-delete']) {
    test('row conflict $scenario can preserve main', () async {
      final b = await create();
      if (scenario == 'insert-insert') {
        await b.database.execute("INSERT INTO products VALUES('b',1,1,NULL)");
        await main.execute("INSERT INTO products VALUES('b',2,2,NULL)");
      } else if (scenario == 'delete-update') {
        await b.database.execute('DELETE FROM products');
        await main.execute('UPDATE products SET price=520');
      } else {
        await b.database.execute('UPDATE products SET price=550');
        await main.execute('DELETE FROM products');
      }
      final before =
          (await main.query('SELECT * FROM products ORDER BY sku')).rows;
      final c = (await b.previewMerge()).conflicts.single;
      expect(
          (await b.merge(resolutions: {c.id: const BranchResolution.useMain()}))
              .appliedRows,
          0);
      expect((await main.query('SELECT * FROM products ORDER BY sku')).rows,
          before);
    });
  }

  test(
      'archive restore, checksum, source identity and pre-merge crash retry receipt',
      () async {
    final b = await create();
    await b.database.execute('UPDATE products SET price=550');
    final checkpoint = await b.exportArchive();
    final restored = await branches.restore(checkpoint);
    handles.add(restored);
    expect(restored.id, b.id);
    expect((await restored.diff()).length, 1);
    await b.merge();
    // Checkpoint still says open: transaction receipt prevents a second merge.
    expect((await restored.merge()).alreadyMerged, isTrue);
    await main.execute('UPDATE products SET price=600');
    expect((await restored.merge()).alreadyMerged, isTrue);
    expect((await row(main)).first, BigInt.from(600));
    await restored.database.execute('UPDATE products SET price=700');
    await expectLater(restored.merge(), throwsA(isA<BranchException>()));
    final bad = Uint8List.fromList(checkpoint)..[10] = 0;
    await expectLater(branches.restore(bad), throwsA(isA<BranchException>()));
    await expectLater(
        SqlitePlusBranches(database: main, sourceId: 'other')
            .restore(checkpoint),
        throwsA(isA<BranchException>()));
    final envelope = jsonDecode(utf8.decode(checkpoint)) as Map;
    envelope['sha256'] = 'wrong';
    await expectLater(
        branches.restore(Uint8List.fromList(utf8.encode(jsonEncode(envelope)))),
        throwsA(isA<BranchException>()));
  });

  test('diff and resolution BLOBs are defensive', () async {
    final b = await create();
    await b.database.execute("UPDATE products SET payload=X'0304'");
    await main.execute("UPDATE products SET payload=X'0506'");
    final preview = await b.previewMerge();
    final c = preview.conflicts.single;
    (c.branchValue as Uint8List)[0] = 99;
    (preview.changes.single.after!['payload'] as Uint8List)[0] = 99;
    expect(c.branchValue, Uint8List.fromList([3, 4]));
    final value = Uint8List.fromList([7, 8]);
    final resolution = BranchResolution.value(value);
    value[0] = 99;
    await b.merge(resolutions: {c.id: resolution});
    expect(
        (await main.query('SELECT payload FROM products')).rows.single.single,
        Uint8List.fromList([7, 8]));
  });

  test('late unique failure rolls back all rows and creates no receipt',
      () async {
    await main.execute('CREATE UNIQUE INDEX unique_price ON products(price)');
    final b = await create();
    await b.database.execute("INSERT INTO products VALUES('b',20,1,NULL)");
    await b.database.execute('UPDATE products SET price=550 WHERE sku=\'a\'');
    await main.execute("INSERT INTO products VALUES('c',20,1,NULL)");
    final before = main.exportImage();
    await expectLater(b.merge(), throwsA(anything));
    expect(main.exportImage(), before);
    expect(b.isMerged, isFalse);
    expect(
        (await main.query(
                "SELECT name FROM sqlite_schema WHERE name='_spb_merges'"))
            .rows,
        isEmpty);
  });

  test('silent REPLACE policy cannot remove unreviewed main rows', () async {
    await main.execute(
        'CREATE TABLE codes(id INTEGER PRIMARY KEY,code TEXT UNIQUE ON CONFLICT REPLACE)');
    await main.execute("INSERT INTO codes VALUES(1,'x')");
    final b = await create();
    await b.database.execute("INSERT INTO codes VALUES(2,'y')");
    await main.execute("INSERT INTO codes VALUES(3,'y')");
    final before = main.exportImage();
    await expectLater(b.merge(), throwsA(isA<BranchException>()));
    expect(main.exportImage(), before);
  });

  test(
      'FK final validation avoids cascade overwrite and restores connection mode',
      () async {
    await main.execute('CREATE TABLE parents(id INTEGER PRIMARY KEY)');
    await main.execute(
        'CREATE TABLE children(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES parents(id) ON DELETE CASCADE)');
    await main.execute('INSERT INTO parents VALUES(1)');
    await main.execute('PRAGMA foreign_keys=ON');
    final b = await create();
    await b.database.execute('DELETE FROM parents');
    await main.execute('INSERT INTO children VALUES(1,1)');
    final before = main.exportImage();
    await expectLater(b.merge(), throwsA(isA<BranchException>()));
    expect(main.exportImage(), before);
    expect((await main.query('PRAGMA foreign_keys')).rows.single.single,
        BigInt.one);
    await main.execute('DELETE FROM children');
    await b.merge();
    expect((await main.query('SELECT * FROM parents')).rows, isEmpty);
  });

  test('schema drift, caller transactions, lifecycle and limits', () async {
    final b = await create();
    await main.execute('BEGIN');
    await expectLater(
        branches.create(name: 'no'), throwsA(isA<BranchException>()));
    await main.execute('ROLLBACK');
    await b.database.execute('BEGIN');
    await expectLater(b.diff(), throwsA(isA<BranchException>()));
    await b.database.execute('ROLLBACK');
    await b.database.execute('ALTER TABLE products ADD COLUMN other TEXT');
    await expectLater(b.diff(), throwsA(isA<BranchException>()));
    await expectLater(b.exportArchive(), throwsA(isA<BranchException>()));
    final small = SqlitePlusBranches(
        database: main,
        sourceId: 'catalog',
        limits: const BranchLimits(maxImageBytes: 512));
    await expectLater(
        small.create(name: 'no'), throwsA(isA<BranchException>()));
    await b.close();
    await expectLater(b.diff(), throwsA(isA<BranchException>()));
    await main.execute("INSERT INTO products VALUES('b',1,1,NULL)");
    await expectLater(
        SqlitePlusBranches(
                database: main,
                sourceId: 'catalog',
                limits: const BranchLimits(maxRows: 1))
            .create(name: 'no'),
        throwsA(isA<BranchException>()));
  });

  for (final ddl in [
    'CREATE TABLE unsupported(x TEXT)',
    'CREATE TABLE unsupported(x TEXT COLLATE NOCASE PRIMARY KEY)',
    'CREATE TABLE unsupported(x REAL PRIMARY KEY)',
    'CREATE TABLE unsupported(x INTEGER PRIMARY KEY,y INTEGER GENERATED ALWAYS AS (x+1))',
    'CREATE TRIGGER unsupported AFTER UPDATE ON products BEGIN SELECT 1; END',
  ]) {
    test('reject unsupported schema: $ddl', () async {
      await main.execute(ddl);
      await expectLater(create(), throwsA(isA<BranchException>()));
    });
  }
  test('multiple fields and rows resolve independently', () async {
    await main.execute("INSERT INTO products VALUES('b',100,10,NULL)");
    final b = await create();
    await b.database
        .execute('UPDATE products SET price=price+10,stock=stock-2');
    await main.execute('UPDATE products SET price=price+20,stock=stock-1');
    final preview = await b.previewMerge();
    expect(preview.conflicts.length, 4);
    final resolutions = <String, BranchResolution>{
      for (final c in preview.conflicts)
        c.id: c.column == 'price'
            ? const BranchResolution.useMain()
            : const BranchResolution.useBranch(),
    };
    await b.merge(preview: preview, resolutions: resolutions);
    expect(
        (await main.query('SELECT price,stock FROM products ORDER BY sku'))
            .rows,
        [
          [BigInt.from(520), BigInt.from(98)],
          [BigInt.from(120), BigInt.from(8)]
        ]);
  });
}
