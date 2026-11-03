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
    expect(find.text('Tables (1)'), findsOneWidget);
    expect(find.text('Indices (0)'), findsOneWidget);
    expect(find.text('Views (0)'), findsOneWidget);
    expect(find.text('Triggers (0)'), findsOneWidget);
    expect(find.text('"title" TEXT NOT NULL'), findsOneWidget);
    expect(find.text('"id" INTEGER PRIMARY KEY'), findsOneWidget);
    await tester.tap(find.byKey(const Key('show-sql')));
    await _frames(tester);
    final code =
        tester.widget<SelectableText>(find.byKey(const Key('sql-code')));
    final shown = code.textSpan!.toPlainText();
    expect(shown, contains('id INTEGER PRIMARY KEY'));
    expect(shown, contains('title TEXT NOT NULL'));
    expect(shown, contains('\n  pages INTEGER'));
    await tester.tap(find.text('Close'));
    await _frames(tester);
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

  testWidgets('SQL pages a result that has no limit', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run('CREATE TABLE nums (n INTEGER)');
    final values = [for (var i = 0; i < 55; i++) '($i)'];
    await session.run('INSERT INTO nums(n) VALUES ${values.join(',')}');
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.text('SQL'));
    await _frames(tester);
    await tester.enterText(
        find.byKey(const Key('sql-input')), 'SELECT n FROM nums');
    await tester.tap(find.byKey(const Key('run-sql')));
    await _frames(tester);
    expect(find.text('1–50'), findsWidgets);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('54'), findsNothing);

    await tester.tap(find.byKey(const Key('sql-page-next')));
    await _frames(tester);
    expect(find.text('51–55'), findsWidgets);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('54'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    await _finish(tester, session);
  });
}
