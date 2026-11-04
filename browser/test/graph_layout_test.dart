import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/src/graph_layout.dart';
import 'package:sqlite_plus_browser/src/schema_graph.dart';
import 'package:sqlite_plus_browser/src/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a changed schema keeps the tables that remain', () {
    final saved = {
      'books': const GraphPoint(40, 80),
      'authors': const GraphPoint(300, 90),
      'gone': const GraphPoint(10, 10),
    };
    final placed = {
      'books': const GraphPoint(24, 24),
      'authors': const GraphPoint(300, 24),
      'notes': const GraphPoint(24, 220),
    };
    final merged = mergeGraphLayout(saved: saved, placed: placed);
    expect(merged.keys, ['books', 'authors', 'notes']);
    expect(merged['books']!.x, 40);
    expect(merged['books']!.y, 80);
    expect(merged['authors']!.y, 90);
    expect(merged['notes']!.x, 24);
    expect(merged.containsKey('gone'), isFalse);
  });

  test('positions round-trip and a corrupt file stays empty', () async {
    final directory = Directory.systemTemp.createTempSync('graph-layout');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/graphs.json');
    const key = '/data/library.db';
    final store = GraphLayoutStore.file(file);
    await store.save(key, {'books': const GraphPoint(12, 34)});
    await store.save(null, {'books': const GraphPoint(1, 1)});

    final loaded = GraphLayoutStore.file(file);
    await loaded.load();
    expect(loaded.read(key)['books']!.x, 12);
    expect(loaded.read(key)['books']!.y, 34);
    expect(loaded.read(null), isEmpty);
    expect(loaded.read('/other.db'), isEmpty);

    file.writeAsStringSync('{');
    final broken = GraphLayoutStore.file(file);
    await broken.load();
    expect(broken.read(key), isEmpty);
  });

  testWidgets('dragging a card is restored, and a missing table is dropped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const key = '/data/library.db';
    final store = GraphLayoutStore.memory();
    final books = _table('books', ['id', 'title']);
    final authors = _table('authors', ['id', 'name']);
    await tester.pumpWidget(_graph(store, key, [books, authors]));
    await tester.pump();

    final origin = store.read(key)['books']!;
    await tester.drag(
      find.byKey(const Key('graph-table-books')),
      const Offset(80, 40),
    );
    await tester.pump();
    final moved = store.read(key)['books']!;
    expect(moved.x, greaterThan(origin.x + 40));
    expect(moved.y, greaterThan(origin.y + 20));
    final kept = store.read(key)['authors']!;

    final notes = _table('notes', ['body']);
    await tester.pumpWidget(_graph(store, key, [authors, notes]));
    await tester.pump();
    final again = store.read(key);
    expect(again.containsKey('books'), isFalse);
    expect(again['authors']!.x, kept.x);
    expect(again['authors']!.y, kept.y);
    expect(again.containsKey('notes'), isTrue);
    expect(find.byKey(const Key('graph-table-books')), findsNothing);
    expect(find.byKey(const Key('graph-table-notes')), findsOneWidget);
  });
}

SchemaObject _table(String name, List<String> columns) {
  return SchemaObject(
    type: 'table',
    name: name,
    table: name,
    sql: null,
    columns: [
      for (final column in columns)
        ColumnInfo(
          name: column,
          type: 'TEXT',
          notNull: false,
          primaryKey: column == 'id',
        ),
    ],
  );
}

Widget _graph(
  GraphLayoutStore store,
  String key,
  List<SchemaObject> objects,
) {
  return MaterialApp(
    home: Scaffold(
      body: SchemaGraph(
        objects: objects,
        layouts: store,
        layoutKey: key,
        onOpen: (_) {},
        onApply: (_) async {},
        onApplyScript: (_) async {},
      ),
    ),
  );
}
