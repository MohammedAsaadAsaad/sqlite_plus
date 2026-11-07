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
    expect(
      formatSearchSummary(0, const Duration(microseconds: 1500)),
      'No matches · 1.500 ms',
    );
    expect(
      formatSearchSummary(1, const Duration(microseconds: 40)),
      '1 match · 40 µs',
    );
    expect(
      formatSearchSummary(493, const Duration(milliseconds: 405)),
      '493 matches · 405.000 ms',
    );
    expect(
      formatSearchSummary(12000, const Duration(seconds: 1), listed: 10000),
      '10,000 of 12,000 matches · 1.000 s',
    );
  });

  test('result pages are 20 hits and reject a page outside the list', () {
    final hits = [
      for (var i = 1; i <= 45; i++)
        ProductMatch(
          rank: i,
          language: 'English',
          sourceLine: i,
          name: 'milk $i',
          score: 1,
        ),
    ];
    expect(catalogPageCount(0), 0);
    expect(catalogPageCount(20), 1);
    expect(catalogPageCount(21), 2);
    expect(catalogPageCount(45), 3);
    expect(catalogPage(hits, 1).map((hit) => hit.rank), [
      for (var i = 1; i <= 20; i++) i,
    ]);
    expect(catalogPage(hits, 3).map((hit) => hit.rank), [
      for (var i = 41; i <= 45; i++) i,
    ]);
    expect(() => catalogPageCount(-1), throwsArgumentError);
    expect(() => catalogPage(hits, 0), throwsArgumentError);
    expect(() => catalogPage(hits, 4), throwsArgumentError);
    expect(() => catalogPage(<ProductMatch>[], 1), throwsArgumentError);
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

  test(
    'a result page loads 20 names and the next page searches again',
    () async {
      final session = CatalogSession();
      addTearDown(session.close);
      await session.insert([
        for (var i = 1; i <= 25; i++)
          ProductLine(language: 'English', sourceLine: i, name: 'milk $i'),
      ]);
      await session.buildIndex();

      final first = await session.searchProducts('milk');
      expect(first.matches, hasLength(20));
      expect(first.total, 25);
      expect(first.matches.first.rank, 1);
      expect(first.searchElapsed, greaterThanOrEqualTo(Duration.zero));

      final second = await session.searchProducts('milk', offset: 20);
      expect(second.matches, hasLength(5));
      expect(second.total, 25);
      expect(second.matches.first.rank, 21);
      expect(
        second.matches.map((hit) => hit.name).toSet().intersection({
          for (final hit in first.matches) hit.name,
        }),
        isEmpty,
      );
      expect(second.searchElapsed, greaterThanOrEqualTo(Duration.zero));

      final past = await session.searchProducts('milk', offset: 40);
      expect(past.matches, isEmpty);
      expect(past.total, 25);
      expect(session.searchProducts('milk', limit: 0), throwsArgumentError);
    },
  );

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

  test(
    'exact hits suppress nearby words; typos fall back within the language',
    () async {
      final session = CatalogSession();
      addTearDown(session.close);
      await session.insert(const [
        ProductLine(
          language: 'English',
          sourceLine: 1,
          name: 'biscuit vanilla',
        ),
        ProductLine(
          language: 'English',
          sourceLine: 2,
          name: 'biscuits chocolate',
        ),
        ProductLine(language: 'Arabic', sourceLine: 1, name: 'حليب طازج'),
      ]);
      await session.buildIndex();
      final exact = await session.searchProducts('biscuit');
      expect(exact.matches.map((hit) => hit.name), ['biscuit vanilla']);
      final nearby = await session.searchProducts('biscut');
      expect(nearby.matches.map((hit) => hit.name), ['biscuit vanilla']);
      expect(
        (await session.searchProducts('حلييب')).matches.single.name,
        'حليب طازج',
      );
      expect(
        (await session.searchProducts(
          'biscut',
          scope: SearchScope.arabic,
        )).total,
        0,
      );
      expect((await session.searchProducts('zzzzzzzz')).total, 0);
      final past = await session.searchProducts('biscut', offset: 20);
      expect(past.matches, isEmpty);
      expect(past.total, 1);
    },
  );

  test(
    'brand alone cannot suppress correction of a misspelled product',
    () async {
      final session = CatalogSession();
      addTearDown(session.close);
      await session.insert(const [
        ProductLine(
          language: 'Arabic',
          sourceLine: 1,
          name: 'بسكويت جودة فانيليا',
        ),
        ProductLine(language: 'Arabic', sourceLine: 2, name: 'سكر جودة ممتاز'),
        ProductLine(
          language: 'Arabic',
          sourceLine: 3,
          name: 'بسكويت شركة ثانية',
        ),
      ]);
      await session.buildIndex();
      for (final query in ['جودة بسكوت', 'بسكوت جودة', 'جودة بسكويت']) {
        final results = await session.searchProducts(query);
        expect(results.total, 1);
        expect(results.matches.single.name, 'بسكويت جودة فانيليا');
      }
    },
  );

  test(
    'five typo searches persist learned alternatives in the catalog image',
    () async {
      final session = CatalogSession();
      addTearDown(session.close);
      await session.insert(const [
        ProductLine(language: 'Arabic', sourceLine: 1, name: 'بسكويت جودة'),
      ]);
      await session.buildIndex();
      for (var i = 0; i < 5; i++) {
        expect((await session.searchProducts('جودة بسكوت')).total, 1);
        expect(session.lastFuzzyLearningChanged, true);
      }
      await session.searchProducts('جودة بسكوت');
      expect(session.lastFuzzyLearningChanged, false);
      final restored = CatalogSession();
      addTearDown(restored.close);
      await restored.openImage(session.exportImage());
      expect((await restored.searchProducts('جودة بسكوت')).total, 1);
      expect(restored.lastFuzzyLearningChanged, false);
    },
  );

  test('precision prioritizes exact names then phrase adjacency and scattered words', () async {
    final session = CatalogSession();
    addTearDown(session.close);
    await session.insert(const [
      ProductLine(language: 'English', sourceLine: 1, name: 'red fresh apple'),
      ProductLine(language: 'English', sourceLine: 2, name: 'apple red'),
      ProductLine(
        language: 'English',
        sourceLine: 3,
        name: 'best red apple now',
      ),
      ProductLine(language: 'English', sourceLine: 4, name: 'red apple'),
    ]);
    await session.buildIndex();
    expect(
      (await session.searchProducts('red apple')).matches.map((m) => m.name),
      ['red apple', 'best red apple now', 'apple red', 'red fresh apple'],
    );
  });

  test('old saved catalog rebuilds once and keeps all products', () async {
    final original = CatalogSession();
    addTearDown(original.close);
    await original.insert(const [
      ProductLine(language: 'English', sourceLine: 1, name: 'biscuit vanilla'),
    ]);
    await original.buildIndex();
    await original.database!.execute('PRAGMA user_version = 0');

    final restored = CatalogSession();
    addTearDown(restored.close);
    await restored.openImage(original.exportImage());
    expect(restored.productCount, 1);
    expect(restored.indexed, isFalse);
    await restored.buildIndex();
    expect(
      (await restored.searchProducts('biscut')).matches.single.name,
      'biscuit vanilla',
    );

    final current = CatalogSession();
    addTearDown(current.close);
    await current.openImage(restored.exportImage());
    expect(current.indexed, isTrue);
    expect(current.productCount, 1);
    expect((await current.searchProducts('biscut')).total, 1);
    expect(current.buildIndex(), throwsStateError);
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
    expect(find.byKey(const Key('search-time')), findsOneWidget);
    expect(find.textContaining('RSS'), findsNothing);
    expect(find.byKey(const Key('page-next')), findsNothing);
  });

  testWidgets('typo fallback shows its time and moves through result pages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = Directory.systemTemp.createTempSync('catalog-pages');
    addTearDown(() => directory.deleteSync(recursive: true));

    Future<List<ProductLine>> products({
      required bool arabic,
      required bool english,
    }) async {
      return [
        for (var i = 1; i <= 25; i++)
          ProductLine(language: 'English', sourceLine: i, name: 'milk $i'),
      ];
    }

    await tester.pumpWidget(
      CatalogApp(
        products: products,
        storeFile: () async => File('${directory.path}/catalog.sqlite'),
      ),
    );
    await _waitForText(tester, 'Ready');
    await tester.enterText(find.byKey(const Key('search-field')), 'milkk');
    await tester.pump();
    await _tap(tester, const Key('search-button'));
    await _waitForText(tester, '1 / 2');
    expect(find.byType(ListTile), findsNWidgets(catalogPageSize));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.textContaining('RSS'), findsNothing);
    expect(find.textContaining('Image'), findsNothing);
    final timing = tester
        .widget<Text>(find.byKey(const Key('search-time')))
        .data;
    expect(timing, contains('20 of 25 matches ·'));

    await _tap(tester, const Key('page-next'));
    await _waitForText(tester, '2 / 2');
    expect(find.byType(ListTile), findsNWidgets(5));
    final nextTiming = tester
        .widget<Text>(find.byKey(const Key('search-time')))
        .data;
    expect(nextTiming, contains('5 of 25 matches ·'));

    await _tap(tester, const Key('page-previous'));
    await _waitForText(tester, '1 / 2');
    expect(find.byType(ListTile), findsNWidgets(catalogPageSize));
    expect(
      tester.widget<Text>(find.byKey(const Key('search-time'))).data,
      contains('20 of 25 matches ·'),
    );
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
