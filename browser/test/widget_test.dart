import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/browser_app.dart';
import 'package:sqlite_plus_browser/src/session.dart';

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _finish(WidgetTester tester, BrowserSession session) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await session.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sample rows show in the grid', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    expect(find.text('Memory'), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-menu')));
    await _frames(tester);
    await tester.tap(find.text('Add sample rows'));
    await _frames(tester);

    expect(find.text('Kept Garden'), findsOneWidget);
    expect(find.text('320'), findsOneWidget);
    expect(find.text('Memory · unsaved'), findsOneWidget);
    expect(find.text('PK'), findsOneWidget);
    expect(find.text('TEXT'), findsOneWidget);
    await _finish(tester, session);
  });

  testWidgets('SQL completion inserts the chosen word', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.text('SQL'));
    await _frames(tester);
    await tester.enterText(find.byKey(const Key('sql-input')), 'SEL');
    await _frames(tester);
    await tester.tap(find.byKey(const Key('suggest-SELECT')));
    await _frames(tester);
    final field = tester.widget<TextField>(find.byKey(const Key('sql-input')));
    expect(field.controller!.text, 'SELECT ');
    await _finish(tester, session);
  });

  testWidgets('SQL creates a table and a cell edit is saved', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.text('SQL'));
    await _frames(tester);
    await tester.enterText(
      find.byKey(const Key('sql-input')),
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, pages INTEGER)',
    );
    await tester.tap(find.byKey(const Key('run-sql')));
    await _frames(tester);
    expect(find.text('0 changed'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('sql-input')),
      "INSERT INTO books(title, pages) VALUES ('Kept Garden', 320)",
    );
    await tester.tap(find.byKey(const Key('run-sql')));
    await _frames(tester);
    expect(find.text('1 changed'), findsOneWidget);

    await tester.tap(find.byKey(const Key('schema-table-books')));
    await _frames(tester);
    expect(find.text('Kept Garden'), findsOneWidget);

    await tester.tap(find.text('320'));
    await _frames(tester);
    await tester.enterText(find.byKey(const Key('cell-editor')), '321');
    await tester.tap(find.byKey(const Key('cell-save')));
    await _frames(tester);
    expect(find.text('321'), findsOneWidget);
    expect(find.text('320'), findsNothing);
    await _finish(tester, session);
  });
}
