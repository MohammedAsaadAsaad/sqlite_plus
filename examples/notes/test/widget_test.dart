import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:margin_notes/app.dart';
import 'package:margin_notes/note_store.dart';

void main() {
  testWidgets('the desk shows the masthead and the compose button', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('margin-ui');
    final store = NoteStore(directory);
    await store.open();
    addTearDown(() => directory.deleteSync(recursive: true));

    await tester.pumpWidget(MarginApp(store: store));

    expect(find.text('هامش'), findsOneWidget);
    expect(find.byKey(const Key('compose')), findsOneWidget);
    expect(find.text('المكتب فارغ'), findsOneWidget);
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
}
