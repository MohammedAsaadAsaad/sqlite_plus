import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/browser_app.dart';
import 'package:sqlite_plus_browser/src/grid.dart';
import 'package:sqlite_plus_browser/src/recent_files.dart';
import 'package:sqlite_plus_browser/src/session.dart';
import 'package:sqlite_plus_browser/src/work_progress.dart';

bool _inSchemaView(WidgetTester tester, Finder finder) {
  final rect = tester.getRect(finder);
  final view = tester.getRect(find.byKey(const Key('schema-list')));
  return rect.bottom > view.top + 1 && rect.top < view.bottom - 1;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _finish(WidgetTester tester, BrowserSession session) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await session.close();
}

RenderEditable _editable(WidgetTester tester) {
  final root = tester.renderObject<RenderObject>(
    find.descendant(
      of: find.byKey(const Key('sql-input')),
      matching: find.byType(EditableText),
    ),
  );
  RenderEditable? found;
  void visit(RenderObject object) {
    if (object is RenderEditable) {
      found = object;
      return;
    }
    object.visitChildren(visit);
  }

  visit(root);
  return found!;
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
    expect(find.text('Schema'), findsNothing);
    expect(find.text('TEXT'), findsNothing);
    expect(find.byIcon(Icons.abc), findsOneWidget);
    expect(find.byIcon(Icons.numbers), findsNWidgets(2));
    expect(find.text('Tables (1)'), findsOneWidget);
    expect(find.text('Indices (0)'), findsOneWidget);
    expect(find.text('Views (0)'), findsOneWidget);
    expect(find.text('Triggers (0)'), findsOneWidget);
    expect(find.text('"title" TEXT NOT NULL'), findsNothing);
    expect(find.text('"id" INTEGER PRIMARY KEY'), findsNothing);
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
    expect(find.byKey(const Key('suggest-SELECT')), findsOneWidget);
    await tester.tap(find.text('Statement'));
    await _frames(tester);
    expect(find.byKey(const Key('suggest-SELECT')), findsNothing);
    await tester.enterText(find.byKey(const Key('sql-input')), 'SE');
    await _frames(tester);
    await tester.tap(find.byKey(const Key('suggest-SELECT')));
    await _frames(tester);
    final field = tester.widget<TextField>(find.byKey(const Key('sql-input')));
    expect(field.controller!.text, 'SELECT ');
    expect(field.style!.fontFamily, 'JetBrainsMono');
    expect(field.style!.color, const Color(0x00000000));
    expect(field.style!.letterSpacing, 0);
    await _finish(tester, session);
  });

  testWidgets('the caret lines up with the highlighted glyphs', (tester) async {
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
    const source = 'CREATE INDEX idx_name ON events (';
    await tester.enterText(find.byKey(const Key('sql-input')), source);
    await _frames(tester);

    final text = tester
        .widget<TextField>(find.byKey(const Key('sql-input')))
        .controller!
        .text;
    final index = text.indexOf('events');
    expect(index, greaterThan(10));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('sql-highlight')),
    );
    final editable = _editable(tester);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: index, extentOffset: index + 6),
    );
    expect(boxes, hasLength(1));
    final caret = editable.localToGlobal(
      editable.getLocalRectForCaret(TextPosition(offset: index)).topLeft,
    );
    final glyph =
        paragraph.localToGlobal(Offset(boxes.single.left, boxes.single.top));
    expect((caret.dx - glyph.dx).abs(), lessThan(1));
    final end = editable.localToGlobal(
      editable.getLocalRectForCaret(TextPosition(offset: index + 6)).topLeft,
    );
    final glyphEnd = paragraph.localToGlobal(
      Offset(boxes.single.right, boxes.single.top),
    );
    expect((end.dx - glyphEnd.dx).abs(), lessThan(1));
    final style = tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('sql-input')),
            matching: find.byType(EditableText),
          ),
        )
        .style;
    expect(style.letterSpacing, 0);
    expect(style.fontFamily, 'JetBrainsMono');
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
    expect(
      tester.widget<Text>(find.byKey(const Key('cell-kind'))).data,
      'INTEGER',
    );
    expect(find.byKey(const Key('cell-step-up')), findsOneWidget);
    expect(find.byKey(const Key('cell-null')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cell-step-up')));
    await _frames(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('cell-editor')))
          .controller!
          .text,
      '321',
    );
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

  testWidgets('the cell editor follows the column type', (tester) async {
    tester.view.physicalSize = const Size(2400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE kinds ('
      'flag INTEGER, note TEXT NOT NULL, amount REAL, '
      'ok BOOLEAN, day DATE, when_at DATETIME, clock TIME)',
    );
    await session.run(
      "INSERT INTO kinds(flag, note, amount, ok, day, when_at, clock) "
      "VALUES (0, 'Kept', 1.5, 1, '2026-11-03', '2026-11-03 09:30:00', '09:30:00')",
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('schema-table-kinds')));
    await _frames(tester);

    await tester.tap(find.text('1.5'));
    await _frames(tester);
    expect(
        tester.widget<Text>(find.byKey(const Key('cell-kind'))).data, 'REAL');
    expect(find.text('Decimal number'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);

    await tester.tap(find.text('Kept'));
    await _frames(tester);
    expect(
        tester.widget<Text>(find.byKey(const Key('cell-kind'))).data, 'TEXT');
    expect(find.text('NOT NULL'), findsOneWidget);
    expect(find.byKey(const Key('cell-null')), findsNothing);
    final note = tester.widget<TextField>(find.byKey(const Key('cell-editor')));
    expect(note.minLines, 3);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);

    await tester.tap(
      find.descendant(of: find.byType(CellGrid), matching: find.text('1')),
    );
    await _frames(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('cell-kind'))).data,
      'BOOLEAN',
    );
    expect(find.text('On'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);

    await tester.tap(find.text('2026-11-03'));
    await _frames(tester);
    expect(
        tester.widget<Text>(find.byKey(const Key('cell-kind'))).data, 'DATE');
    expect(find.byKey(const Key('cell-pick-date')), findsOneWidget);
    expect(find.byKey(const Key('cell-pick-time')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);

    await tester.tap(find.text('2026-11-03 09:30:00'));
    await _frames(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('cell-kind'))).data,
      'DATETIME',
    );
    expect(find.byKey(const Key('cell-pick-date')), findsOneWidget);
    expect(find.byKey(const Key('cell-pick-time')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);

    await tester.tap(find.text('09:30:00'));
    await _frames(tester);
    expect(
        tester.widget<Text>(find.byKey(const Key('cell-kind'))).data, 'TIME');
    expect(find.byKey(const Key('cell-pick-time')), findsOneWidget);
    expect(find.byKey(const Key('cell-pick-date')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);

    await tester.tap(
      find.descendant(of: find.byType(CellGrid), matching: find.text('0')),
    );
    await _frames(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('cell-kind'))).data,
      'INTEGER',
    );
    expect(find.text('Whole number'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);
    await _finish(tester, session);
  });

  testWidgets('a phone keeps the query and the result apart', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run('CREATE TABLE tiny (n INTEGER)');
    await session.run('INSERT INTO tiny(n) VALUES (0)');
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.byKey(const Key('pane-sql')));
    await _frames(tester);
    await tester.enterText(
      find.byKey(const Key('sql-input')),
      'SELECT n FROM tiny',
    );
    expect(find.byKey(const Key('sql-grid')), findsNothing);
    expect(find.byKey(const Key('sql-page-next')), findsNothing);
    await tester.tap(find.byKey(const Key('run-sql')));
    await _frames(tester);
    expect(find.byKey(const Key('sql-grid')), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.byKey(const Key('sql-input')), findsNothing);

    await tester.tap(find.byKey(const Key('sql-show-query')));
    await _frames(tester);
    expect(find.byKey(const Key('sql-input')), findsOneWidget);
    expect(find.byKey(const Key('sql-grid')), findsNothing);
    await _finish(tester, session);
  });

  testWidgets('create table and create index stay in a form', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.byKey(const Key('schema-add-table')));
    await _frames(tester);
    await tester.enterText(find.byKey(const Key('create-table-name')), 'notes');
    await _frames(tester);
    await tester.tap(find.byKey(const Key('create-table-save')));
    await _frames(tester);
    expect(find.byKey(const Key('schema-table-notes')), findsOneWidget);
    expect(find.byKey(const Key('sql-input')), findsNothing);
    expect(find.text('New table'), findsNothing);

    await tester.tap(find.byKey(const Key('schema-add-index')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('create-index-column-title')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('create-index-save')));
    await _frames(tester);
    expect(
        find.byKey(const Key('schema-index-idx_notes_title')), findsOneWidget);
    expect(find.byKey(const Key('sql-input')), findsNothing);
    expect(find.text('Create table'), findsNothing);
    expect(find.text('Create index'), findsNothing);
    await tester.tap(find.byKey(const Key('schema-index-idx_notes_title')));
    await _frames(tester);
    expect(
        tester.widget<Text>(find.byKey(const Key('index-entries'))).data, '0');
    expect(
      tester.widget<Text>(find.byKey(const Key('index-size'))).data,
      endsWith('KB'),
    );
    await _finish(tester, session);
  });

  testWidgets('the graph adds a foreign key between two tables',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)',
    );
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT)',
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.text('Graph'));
    await _frames(tester);
    final before =
        tester.getTopLeft(find.byKey(const Key('graph-table-books')));
    await tester.drag(
      find.byKey(const Key('graph-table-books')),
      const Offset(70, 36),
    );
    await tester.pump();
    final after = tester.getTopLeft(find.byKey(const Key('graph-table-books')));
    expect(after.dx, greaterThan(before.dx + 40));
    expect(after.dy, greaterThan(before.dy + 20));
    final parked =
        tester.getTopLeft(find.byKey(const Key('graph-table-authors')));
    await tester.dragFrom(
        parked + const Offset(260, 20), const Offset(-48, -32));
    await tester.pump();
    final panned =
        tester.getTopLeft(find.byKey(const Key('graph-table-authors')));
    expect(panned.dx, lessThan(parked.dx - 20));
    expect(panned.dy, lessThan(parked.dy - 15));

    expect(find.textContaining('Drag a table'), findsNothing);
    expect(find.textContaining('Tap a column'), findsNothing);
    await tester.tap(find.byKey(const Key('graph-column-books-title')));
    await _frames(tester);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('graph-column-authors-name')))
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('graph-column-books-id')))
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('graph-column-authors-id')))
          .onTap,
      isNotNull,
    );
    expect(find.byIcon(Icons.link), findsOneWidget);
    await tester.tap(find.byKey(const Key('graph-column-authors-name')));
    await _frames(tester);
    expect(find.text('Confirm relationship'), findsNothing);

    await tester.tap(find.byKey(const Key('graph-column-authors-id')));
    await _frames(tester);
    expect(find.text('books.title → authors.id'), findsOneWidget);
    expect(find.text('→ authors.id'), findsNothing);
    await tester.tap(find.byKey(const Key('link-save')));
    await _frames(tester);
    expect(find.text('→ authors.id'), findsOneWidget);
    expect(find.text('title'), findsWidgets);
    await tester.tap(find.byKey(const Key('graph-column-books-title')));
    await _frames(tester);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('graph-column-authors-id')))
          .onTap,
      isNull,
    );
    await tester.tap(find.byKey(const Key('graph-column-books-title')));
    await _frames(tester);
    final board = tester.getSize(find.byKey(const Key('graph-board')));
    await tester.tap(find.byKey(const Key('graph-zoom-in')));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('graph-board'))).width,
      greaterThan(board.width),
    );
    await tester.tap(find.byKey(const Key('graph-zoom-out')));
    await tester.pump();
    await _finish(tester, session);
  });

  testWidgets('the progress card names the running statement', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: WorkProgress(
          detail: 'CREATE INDEX idx_name ON events (category)',
        ),
      ),
    );
    expect(find.byKey(const Key('work-progress')), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(
      find.byKey(const Key('work-progress-detail')),
      findsOneWidget,
    );
    expect(find.textContaining('idx_name'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('running a statement shows the progress card first',
      (tester) async {
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
      'CREATE TABLE pace (id INTEGER)',
    );
    await tester.tap(find.byKey(const Key('run-sql')));
    await tester.pump();
    expect(find.byKey(const Key('work-progress')), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('CREATE TABLE pace'), findsWidgets);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('work-progress')), findsNothing);
    expect(find.text('0 changed'), findsOneWidget);
    expect(find.byKey(const Key('schema-table-pace')), findsOneWidget);
    await _finish(tester, session);
  });

  testWidgets('creating an index shows progress above the schema drawer',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run('CREATE TABLE notes (title TEXT)');
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('schema-add-index')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('create-index-column-title')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('create-index-save')));
    await tester.pump();
    expect(find.byKey(const Key('work-progress')), findsOneWidget);
    final card = tester.renderObject(find.byKey(const Key('work-progress')));
    final hit = tester.hitTestOnBinding(
      tester.getCenter(find.byKey(const Key('work-progress'))),
    );
    RenderObject? node = hit.path.first.target as RenderObject;
    var above = false;
    while (node != null) {
      if (identical(node, card)) {
        above = true;
        break;
      }
      final parent = node.parent;
      if (parent is! RenderObject) break;
      node = parent;
    }
    expect(above, isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('work-progress')), findsNothing);
    expect(
      find.byKey(const Key('schema-index-idx_notes_title')),
      findsOneWidget,
    );
    await _finish(tester, session);
  });

  testWidgets('add column collects the properties of a new column',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE events (id INTEGER PRIMARY KEY, category TEXT)',
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.byKey(const Key('schema-add-column-events')));
    await _frames(tester);
    await tester.enterText(find.byKey(const Key('add-column-name')), 'note');
    await tester.tap(find.byKey(const Key('add-column-null')));
    await _frames(tester);
    expect(find.text('Existing rows need a default.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('add-column-save')))
            .onPressed,
        isNull);
    await tester.enterText(find.byKey(const Key('add-column-default')), 'Kept');
    await _frames(tester);
    await tester.tap(find.byKey(const Key('add-column-save')));
    await _frames(tester);
    expect(find.text('note'), findsOneWidget);
    expect(find.textContaining('"note" TEXT NOT NULL'), findsNothing);
    expect(find.byKey(const Key('sql-input')), findsNothing);
    await tester.tap(find.byKey(const Key('schema-table-events')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('show-sql')));
    await _frames(tester);
    final noteSql = tester
        .widget<SelectableText>(find.byKey(const Key('sql-code')))
        .textSpan!
        .toPlainText();
    expect(noteSql, contains('"note" TEXT NOT NULL DEFAULT \'Kept\''));
    await _finish(tester, session);
  });

  testWidgets('home offers open and the recent databases', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = Directory.systemTemp.createTempSync('browser-recents');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final seed = BrowserSession();
    await seed.openEmpty();
    await seed.run(
      'CREATE TABLE events (id INTEGER PRIMARY KEY, category TEXT)',
    );
    await seed.run("INSERT INTO events (category) VALUES ('kept')");
    final bytes = seed.exportBytes();
    await seed.close();
    final location = '${dir.path}/sample.db';
    File(location).writeAsBytesSync(bytes);
    final store = RecentStore.directory(dir);
    await store.remember(name: 'sample.db', bytes: bytes, location: location);
    final reloaded = RecentStore.directory(dir);
    await reloaded.load();
    expect(reloaded.files.single.name, 'sample.db');

    final session = BrowserSession();
    await tester.pumpWidget(BrowserApp(session: session, recents: reloaded));
    await _frames(tester);
    expect(find.text('SQLite Browser'), findsWidgets);
    expect(find.byKey(const Key('home-open')), findsOneWidget);
    expect(find.text('sample.db'), findsOneWidget);
    expect(find.byKey(const Key('schema-list')), findsNothing);

    await tester.tap(find.byKey(const Key('recent-0')));
    await _frames(tester);
    expect(find.byKey(const Key('schema-table-events')), findsOneWidget);
    await tester.tap(find.byKey(const Key('schema-table-events')));
    await _frames(tester);
    expect(find.text('kept'), findsOneWidget);
    expect(find.byKey(const Key('home-open')), findsNothing);
    await _finish(tester, session);
  });

  testWidgets('a column menu sorts and searches the whole table',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, pages INTEGER)',
    );
    await session.run(
      "INSERT INTO books (title, pages) VALUES ('Kept Garden', 320), "
      "('Other Atlas', 40)",
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('schema-table-books')));
    await _frames(tester);
    expect(find.text('Filter'), findsNothing);
    expect(find.text('Kept Garden'), findsOneWidget);
    expect(find.text('Other Atlas'), findsOneWidget);

    await tester.tap(find.byKey(const Key('column-menu-pages')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('column-sort-asc')));
    await _frames(tester);
    expect(
      tester.getTopLeft(find.text('Other Atlas')).dy,
      lessThan(tester.getTopLeft(find.text('Kept Garden')).dy),
    );

    await tester.tap(find.byKey(const Key('column-menu-title')));
    await _frames(tester);
    await tester.enterText(find.byKey(const Key('column-search')), 'Kept');
    await tester.tap(find.byKey(const Key('column-search-apply')));
    await _frames(tester);
    expect(find.text('Kept Garden'), findsOneWidget);
    expect(find.text('Other Atlas'), findsNothing);
    await _finish(tester, session);
  });

  testWidgets('close leaves the home screen and keeps a dirty database',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run('CREATE TABLE books (id INTEGER PRIMARY KEY)');
    await session.run('INSERT INTO books DEFAULT VALUES');
    expect(session.dirty, isTrue);
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    expect(find.byKey(const Key('schema-table-books')), findsOneWidget);

    await tester.tap(find.byKey(const Key('more-menu')));
    await _frames(tester);
    await tester.tap(find.text('Close database'));
    await _frames(tester);
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await _frames(tester);
    expect(find.byKey(const Key('schema-table-books')), findsOneWidget);
    expect(session.isOpen, isTrue);

    await tester.tap(find.byKey(const Key('more-menu')));
    await _frames(tester);
    await tester.tap(find.text('Close database'));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('discard-changes')));
    await _frames(tester);
    expect(find.byKey(const Key('home-open')), findsOneWidget);
    expect(find.byKey(const Key('schema-table-books')), findsNothing);
    expect(session.isOpen, isFalse);
    expect(session.dirty, isFalse);
    await _finish(tester, session);
  });

  testWidgets('New, Open, and Save are in the more menu', (tester) async {
    tester.view.physicalSize = const Size(420, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    expect(find.byKey(const Key('new-database')), findsNothing);
    expect(find.byIcon(Icons.save_outlined), findsNothing);
    final title = tester.renderObject<RenderParagraph>(
      find.text('SQLite Browser'),
    );
    expect(title.didExceedMaxLines, isFalse);
    await tester.tap(find.byKey(const Key('more-menu')));
    await _frames(tester);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuItem<String>>(find.byKey(const Key('save-database')))
          .enabled,
      isTrue,
    );
    await _finish(tester, session);
  });

  testWidgets('a text column shows its length beside the symbol',
      (tester) async {
    tester.view.physicalSize = const Size(420, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE cities (name NVARCHAR(160), code INTEGER)',
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await _frames(tester);
    expect(find.text('Schema'), findsNothing);
    expect(find.textContaining('NVARCHAR'), findsNothing);
    expect(find.text('160'), findsOneWidget);
    expect(find.byIcon(Icons.abc), findsOneWidget);
    expect(find.byIcon(Icons.numbers), findsOneWidget);
    final length = tester.getTopLeft(find.text('160'));
    final list = tester.getRect(find.byKey(const Key('schema-list')));
    expect(length.dx, greaterThan(list.left));
    expect(length.dx, lessThan(list.right));
    await _finish(tester, session);
  });

  testWidgets('reopening the schema drawer scrolls to the open table',
      (tester) async {
    tester.view.physicalSize = const Size(420, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    for (var i = 0; i < 10; i++) {
      await session.run('CREATE TABLE t$i (a TEXT, b TEXT, c TEXT, d TEXT)');
    }
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await _frames(tester);
    final table = find.byKey(const Key('schema-table-t9'));
    await tester.scrollUntilVisible(
      table,
      400,
      scrollable: find.descendant(
        of: find.byKey(const Key('schema-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tapAt(tester.getTopLeft(table) + const Offset(48, 16));
    await _frames(tester);
    expect(find.byKey(const Key('schema-list')), findsNothing);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await _frames(tester);
    expect(
      _inSchemaView(tester, find.byKey(const Key('schema-table-t9'))),
      isTrue,
    );
    expect(
      _inSchemaView(tester, find.byKey(const Key('schema-table-t0'))),
      isFalse,
    );
    await _finish(tester, session);
  });

  testWidgets('Dart classes explain how to run the generator', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT NOT NULL)',
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('more-menu')));
    await _frames(tester);
    await tester.tap(find.text('Dart classes'));
    await _frames(tester);
    expect(find.byKey(const Key('model-step-2')), findsNothing);
    expect(find.text('dart run sqlite_plus_generator'), findsNothing);
    expect(find.byKey(const Key('model-class-Books')), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('model-code-Books')))
          .textSpan!
          .toPlainText(),
      contains('class Books'),
    );
    await tester.tap(find.byKey(const Key('models-help')));
    await _frames(tester);
    expect(find.byKey(const Key('model-step-2')), findsOneWidget);
    expect(find.text('dart run sqlite_plus_generator'), findsOneWidget);
    expect(find.text('Put the classes in lib/'), findsOneWidget);
    expect(find.textContaining('--input'), findsNothing);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    await tester.tap(find.byKey(const Key('models-copy')));
    await _frames(tester);
    expect(find.text('Copied'), findsOneWidget);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    await tester.tap(find.text('Close'));
    await _frames(tester);
    expect(find.byKey(const Key('model-class-Books')), findsNothing);
    await _finish(tester, session);
  });

  testWidgets('deleting a row or a delete statement asks first',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT)',
    );
    await session.run(
      "INSERT INTO books (title) VALUES ('Kept Garden'), ('Other Atlas')",
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('schema-table-books')));
    await _frames(tester);

    await tester.tap(find.byKey(const Key('delete-row-0')));
    await _frames(tester);
    expect(find.text('Delete this row?'), findsOneWidget);
    expect(find.text('This removes one row from books.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-dismiss')));
    await _frames(tester);
    expect(find.text('Kept Garden'), findsOneWidget);
    expect(find.text('Other Atlas'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-row-0')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await _frames(tester);
    expect(find.text('Kept Garden'), findsNothing);
    expect(find.text('Other Atlas'), findsOneWidget);

    await tester.tap(find.text('SQL'));
    await _frames(tester);
    await tester.enterText(
      find.byKey(const Key('sql-input')),
      'DELETE FROM books',
    );
    await tester.tap(find.byKey(const Key('run-sql')));
    await _frames(tester);
    expect(find.text('Delete these rows?'), findsOneWidget);
    expect(find.text('DELETE FROM books'), findsWidgets);
    await tester.tap(find.byKey(const Key('delete-dismiss')));
    await _frames(tester);
    await tester.tap(find.text('Rows'));
    await _frames(tester);
    expect(find.text('Other Atlas'), findsOneWidget);

    await tester.tap(find.text('SQL'));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('run-sql')));
    await _frames(tester);
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await _frames(tester);
    expect(find.text('1 changed'), findsOneWidget);
    await tester.tap(find.text('Rows'));
    await _frames(tester);
    expect(find.text('Other Atlas'), findsNothing);
    await _finish(tester, session);
  });

  testWidgets('a column suggestion shows its declared type', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    await session.openEmpty();
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, pages INTEGER)',
    );
    await tester.pumpWidget(BrowserApp(session: session));
    await _frames(tester);
    await tester.tap(find.text('SQL'));
    await _frames(tester);
    await tester.enterText(find.byKey(const Key('sql-input')), 'SELECT ');
    await _frames(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('suggest-type-title'))).data,
      'TEXT',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('suggest-type-id'))).data,
      'INTEGER',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('suggest-type-pages'))).data,
      'INTEGER',
    );
    expect(find.text('column'), findsNothing);
    await _finish(tester, session);
  });
}
