import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margin_notes/app.dart';
import 'package:margin_notes/note_exchange.dart';
import 'package:margin_notes/note_store.dart';
import 'package:margin_notes/notes_plot_page.dart';

void main() {
  testWidgets('the desk shows the masthead and the compose button', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('margin-ui');
    final store = NoteStore(directory);
    await store.open();
    addTearDown(() => directory.deleteSync(recursive: true));

    await tester.pumpWidget(MarginApp(store: store));

    expect(find.text('Margin'), findsOneWidget);
    expect(find.byKey(const Key('compose')), findsOneWidget);
    expect(find.text('The desk is empty'), findsOneWidget);
    await store.close();
  });

  testWidgets('compose opens the editor', (tester) async {
    final directory = Directory.systemTemp.createTempSync('margin-editor');
    final store = NoteStore(directory);
    await store.open();
    addTearDown(() => directory.deleteSync(recursive: true));

    await tester.pumpWidget(MarginApp(store: store));
    await tester.tap(find.byKey(const Key('compose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('title-field')), findsOneWidget);
    expect(find.byKey(const Key('body-field')), findsOneWidget);
    expect(find.byKey(const Key('editor-save')), findsOneWidget);
    await store.close();
  });

  testWidgets('tools exposes insert, delete, details, and vacuum', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('margin-tools');
    final store = NoteStore(directory);
    await store.open();
    addTearDown(() => directory.deleteSync(recursive: true));

    await tester.pumpWidget(MarginApp(store: store));
    await tester.tap(find.byKey(const Key('tools')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('insert-count')), findsOneWidget);
    expect(find.byKey(const Key('insert-transaction')), findsOneWidget);
    expect(find.byKey(const Key('insert-run')), findsOneWidget);
    expect(find.byKey(const Key('delete-all')), findsOneWidget);
    expect(find.byKey(const Key('live-metrics')), findsOneWidget);
    expect(find.byKey(const Key('database-details')), findsOneWidget);
    expect(find.byKey(const Key('vacuum-run')), findsOneWidget);
    await store.close();
  });

  testWidgets('live metrics samples RSS and then leaves no timer', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('margin-metrics');
    final store = NoteStore(directory);
    await store.open();
    addTearDown(() => directory.deleteSync(recursive: true));

    await tester.pumpWidget(MarginApp(store: store));
    await tester.tap(find.byKey(const Key('tools')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('live-metrics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('metrics-rss')), findsOneWidget);
    expect(find.byKey(const Key('metrics-cpu')), findsOneWidget);
    expect(find.byKey(const Key('metrics-peak')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('metrics-rss')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('metrics-rss')), findsNothing);
    await store.close();
  });

  testWidgets('live metrics stays open while a job is running', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'margin-metrics-busy',
    );
    final store = NoteStore(directory);
    await store.open();
    addTearDown(() => directory.deleteSync(recursive: true));
    store.busy = true;

    await tester.pumpWidget(MarginApp(store: store));
    await tester.tap(find.byKey(const Key('tools')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('live-metrics')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('delete-all')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('live-metrics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('metrics-rss')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('metrics-rss')), findsNothing);
    await store.close();
  });

  testWidgets('an empty plot says there is nothing to draw', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: NotesPlotPage(bars: [])),
    );
    expect(find.byKey(const Key('plot-empty')), findsOneWidget);
    expect(find.text('Notes by day'), findsOneWidget);
  });

  testWidgets('tools import a CSV row and plot its UTC day', (tester) async {
    final directory = Directory.systemTemp.createTempSync('margin-csv');
    final store = NoteStore(directory);
    await store.open();
    addTearDown(() => directory.deleteSync(recursive: true));

    await tester.pumpWidget(MarginApp(store: store));
    await tester.tap(find.byKey(const Key('tools')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.scrollUntilVisible(find.byKey(const Key('export-csv')), 200);
    await tester.tap(find.byKey(const Key('export-csv')));
    await tester.pump();
    expect(find.textContaining(csvHeader), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('csv-text')),
      '$csvHeader\n,Hello,"a, b",1,2026-11-01T00:00:00.000Z,3\n',
    );
    await tester.scrollUntilVisible(find.byKey(const Key('import-csv')), 200);
    await tester.tap(find.byKey(const Key('import-csv')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Imported 1 notes'), findsOneWidget);
    expect(store.notes, hasLength(1));
    expect(store.notes.single.title, 'Hello');
    expect(store.notes.single.body, 'a, b');

    await tester.scrollUntilVisible(find.byKey(const Key('plot-notes')), 200);
    await tester.tap(find.byKey(const Key('plot-notes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('plot-2026-11-01')), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await store.close();
  });
}
