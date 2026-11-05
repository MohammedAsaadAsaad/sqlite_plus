import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:product_catalog/app.dart';
import 'package:product_catalog/catalog_format.dart';
import 'package:product_catalog/catalog_work.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('elapsed and size text keep the sample readable', () {
    expect(formatElapsed(const Duration(microseconds: 40)), '40 µs');
    expect(formatElapsed(const Duration(microseconds: 1500)), '1.500 ms');
    expect(formatElapsed(const Duration(microseconds: 4704192)), '4.704 s');
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1216512), '1.16 MB');
  });

  test(
    'names move 1,000 at a time and the next batch continues the ids',
    () async {
      final text = List.filled(1001, 'milk').join('\n');
      expect(countProductNames(text), 1001);
      final batches = productBatches(text, 'English').toList();
      expect(batches.map((batch) => batch.length), [1000, 1]);

      final session = CatalogSession();
      addTearDown(session.close);
      expect(await session.insertChunk(batches.first), 1000);
      expect(await session.insertChunk(batches.last), 1001);
      final rows = await session.database!.query(
        'SELECT id FROM products WHERE id IN (1, 1000, 1001) ORDER BY id',
      );
      expect(rows.rows.map((row) => row[0]).toList(), [
        BigInt.one,
        BigInt.from(1000),
        BigInt.from(1001),
      ]);
    },
  );

  test('blank lines are not products and source lines stay 1-based', () {
    final products = parseProductFile('alpha\n\nbeta\n', 'English');
    expect(products.map((line) => line.sourceLine), [1, 3]);
    expect(products.map((line) => line.name), ['alpha', 'beta']);
  });

  test('empty input and search before an index are refused', () async {
    final session = CatalogSession();
    addTearDown(session.close);
    expect(session.insert(const []), throwsArgumentError);
    expect(session.buildIndex(), throwsStateError);
    expect(session.searchProducts('milk'), throwsStateError);
  });

  test('load, index, and search record time, image size, and RSS', () async {
    final session = CatalogSession();
    addTearDown(session.close);
    const products = [
      ProductLine(
        language: 'Arabic',
        sourceLine: 1,
        name: 'لبن جهينة رائب طازج',
      ),
      ProductLine(
        language: 'Arabic',
        sourceLine: 2,
        name: 'أرز مصري حبة طويلة',
      ),
      ProductLine(
        language: 'English',
        sourceLine: 1,
        name: 'yogurt Juhayna drinkable',
      ),
      ProductLine(
        language: 'English',
        sourceLine: 2,
        name: 'rice Egyptian long grain',
      ),
    ];

    final inserted = await measurePhase<int>(
      title: 'Insert products',
      database: () => session.database,
      action: () => session.insert(products),
      detail: (count) => '$count rows',
    );
    expect(inserted.value, 4);
    expect(inserted.report.elapsed, greaterThanOrEqualTo(Duration.zero));
    expect(inserted.report.imageBefore, 0);
    expect(inserted.report.imageAfter, greaterThan(0));
    expect(inserted.report.rssAfter, greaterThan(0));
    expect(
      inserted.report.peakRss,
      greaterThanOrEqualTo(inserted.report.rssAfter),
    );

    final indexed = await measurePhase<void>(
      title: 'Build search index',
      database: () => session.database,
      action: session.buildIndex,
      detail: (_) => 'indexed',
    );
    expect(indexed.report.imageAfter, greaterThan(inserted.report.imageAfter));
    expect(session.indexed, isTrue);
    expect(session.buildIndex(), throwsStateError);

    final milk = await session.searchProducts('لبن');
    expect(milk.total, greaterThan(0));
    expect(milk.matches.first.name, contains('لبن'));
    expect(milk.searchElapsed, greaterThanOrEqualTo(Duration.zero));

    final yogurt = await session.searchProducts('yogurt');
    expect(yogurt.matches.single.name, contains('yogurt'));

    final arabicOnly = await session.searchProducts(
      'yogurt',
      scope: SearchScope.arabic,
    );
    expect(arabicOnly.total, 0);
    expect(arabicOnly.matches, isEmpty);
  });

  test('bundled catalogs contain 10000 aligned names', () async {
    final arabic = parseProductFile(
      await rootBundle.loadString('assets/products/arabic_products_10k.txt'),
      'Arabic',
    );
    final english = parseProductFile(
      await rootBundle.loadString('assets/products/english_products_10k.txt'),
      'English',
    );
    expect(arabic, hasLength(10000));
    expect(english, hasLength(10000));
    expect(arabic.first.name, 'بسكويت دايجستف بالفانيليا علبة 50 غرام');
    expect(english.first.name, 'biscuit Digestive vanilla box 50 g');
    expect(arabic.last.name, isNotEmpty);
    expect(english.last.name, isNotEmpty);
  });

  test('a slice of the bundled lists is searchable', () async {
    final arabic = parseProductFile(
      await rootBundle.loadString('assets/products/arabic_products_10k.txt'),
      'Arabic',
    ).take(30);
    final english = parseProductFile(
      await rootBundle.loadString('assets/products/english_products_10k.txt'),
      'English',
    ).take(30);
    final session = CatalogSession();
    addTearDown(session.close);
    await session.insert([...arabic, ...english]);
    await session.buildIndex();

    final arabicHits = await session.searchProducts('بسكويت');
    final englishHits = await session.searchProducts('biscuit');
    expect(arabicHits.matches.first.name, contains('بسكويت'));
    expect(englishHits.matches.first.name.toLowerCase(), contains('biscuit'));
    expect(arabicHits.matches.first.language, 'Arabic');
    expect(englishHits.matches.first.language, 'English');
  });

  test('a saved image opens ready to search', () async {
    final original = CatalogSession();
    await original.insert(const [
      ProductLine(language: 'Arabic', sourceLine: 1, name: 'لبن قديم'),
    ]);
    await original.buildIndex();
    final bytes = original.exportImage();
    await original.close();

    final restored = CatalogSession();
    addTearDown(restored.close);
    await restored.openImage(bytes);
    expect(restored.indexed, isTrue);
    expect(restored.productCount, 1);
    final hits = await restored.searchProducts('لبن');
    expect(hits.matches.single.name, 'لبن قديم');
  });

  testWidgets('the catalog is prepared once and search stays on screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = Directory.systemTemp.createTempSync('catalog-screen');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = File('${directory.path}/catalog.sqlite');
    var loads = 0;

    Future<List<ProductLine>> products({
      required bool arabic,
      required bool english,
    }) async {
      loads += 1;
      return const [
        ProductLine(language: 'Arabic', sourceLine: 1, name: 'لبن قديم'),
      ];
    }

    Future<File> storeFile() async => store;

    await tester.pumpWidget(
      CatalogApp(
        key: const Key('launch-1'),
        products: products,
        storeFile: storeFile,
      ),
    );
    expect(find.byKey(const Key('load-products')), findsNothing);
    expect(find.byKey(const Key('build-index')), findsNothing);
    expect(find.byKey(const Key('search-field')), findsOneWidget);

    await _waitForText(tester, 'Ready');
    expect(loads, 1);
    expect(store.existsSync(), isTrue);
    expect(find.text('Load products'), findsNothing);
    expect(find.text('Build index'), findsNothing);

    await tester.enterText(find.byKey(const Key('search-field')), 'لبن');
    await tester.pump();
    await _tap(tester, const Key('search-button'));
    await _waitForText(tester, 'لبن قديم');

    await tester.tap(find.byKey(const Key('catalog-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Load products'), findsOneWidget);
    expect(find.text('Rebuild index'), findsOneWidget);
    expect(find.text('Sample resources'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.pumpWidget(
      CatalogApp(
        key: const Key('launch-2'),
        products: products,
        storeFile: storeFile,
      ),
    );
    await _waitForText(tester, 'Ready');
    expect(loads, 1);
    await tester.enterText(find.byKey(const Key('search-field')), 'لبن');
    await tester.pump();
    await _tap(tester, const Key('search-button'));
    await _waitForText(tester, 'لبن قديم');
  });
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  await tester.pump();
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.text(text).evaluate().isNotEmpty &&
        find.byKey(const Key('busy')).evaluate().isEmpty) {
      return;
    }
  }
  final visible = find
      .byType(Text)
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .join(' | ');
  fail('Timed out waiting for "$text". Visible: $visible');
}
