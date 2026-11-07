import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/browser_app.dart';
import 'package:sqlite_plus_browser/src/course_grade.dart';
import 'package:sqlite_plus_browser/src/course_lessons.dart';
import 'package:sqlite_plus_browser/src/course_progress.dart';
import 'package:sqlite_plus_browser/src/session.dart';

const _pickedFill = Color(0xFFFFE4C4);
const _okFill = Color(0xFFD6EBE4);
const _errorFill = Color(0xFFF8D6D2);

Color _choiceFill(WidgetTester tester, int index) {
  final tiles = find.ancestor(
    of: find.byKey(Key('mcq-choice-$index')),
    matching: find.byType(AnimatedContainer),
  );
  for (final element in tiles.evaluate()) {
    final widget = element.widget;
    if (widget is! AnimatedContainer) continue;
    final decoration = widget.decoration;
    if (decoration is BoxDecoration &&
        decoration.borderRadius == BorderRadius.circular(14)) {
      return decoration.color!;
    }
  }
  throw StateError('choice $index has no colored tile');
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var step = 0; step < 40; step++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}

Future<void> _finish(WidgetTester tester, BrowserSession session) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await session.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a statement is rejected until it matches the step', () async {
    final query = sqlCourse[0].tasks[0];
    final empty = await gradeSql(query, '   ');
    expect(empty.passed, isFalse);
    expect(empty.message, 'Write a statement.');

    final pair = await gradeSql(
      query,
      'SELECT title FROM books; SELECT pages FROM books;',
    );
    expect(pair.message, 'Write one statement.');

    final change = sqlCourse
        .expand((lesson) => lesson.tasks)
        .firstWhere((task) => task.probe != null);
    final read = await gradeSql(change, 'SELECT title, pages FROM books;');
    expect(
      read.message,
      'This step changes rows. Write the change, not a query.',
    );

    final wrote = await gradeSql(
      query,
      "INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);",
    );
    expect(wrote.message, 'This step is a query. Write a SELECT.');

    final mismatch = await gradeSql(query, 'SELECT title FROM books;');
    expect(mismatch.passed, isFalse);
    expect(mismatch.message, 'The result does not match.');

    final ordered = sqlCourse[2].tasks[0];
    final reversed = await gradeSql(
      ordered,
      'SELECT title, pages FROM books ORDER BY pages ASC;',
    );
    expect(reversed.passed, isFalse);
    expect(reversed.message, 'The result does not match.');
  });

  test('every example runs and every official statement passes', () async {
    expect(sqlChapters.length, 6);
    expect(sqlCourse.length, greaterThan(12));
    for (final chapter in sqlChapters) {
      expect(chapter.lessons, isNotEmpty);
      expect(chapter.review.length, greaterThanOrEqualTo(4));
      for (final question in chapter.review) {
        expect(
            question.answer, inInclusiveRange(0, question.choices.length - 1));
      }
    }
    for (final lesson in sqlCourse) {
      expect(lesson.parts.length, greaterThanOrEqualTo(2));
      expect(lesson.review.length, greaterThanOrEqualTo(3));
      expect(lesson.tasks, isNotEmpty);
      for (final part in lesson.parts) {
        expect(
          part.question.answer,
          inInclusiveRange(0, part.question.choices.length - 1),
        );
        final table = await runExample(part.example);
        expect(table.columns, isNotEmpty,
            reason: '${lesson.title} ${part.title}');
      }
      for (var index = 0; index < lesson.tasks.length; index++) {
        final task = lesson.tasks[index];
        final grade = await gradeSql(task, task.statement);
        expect(
          grade.passed,
          isTrue,
          reason: '${lesson.title} task $index: ${grade.message}',
        );
        expect(grade.message, 'Passed');
      }
    }
  });

  test('progress opens the next level and keeps a corrupt file closed',
      () async {
    final memory = CourseProgress.memory();
    expect(memory.isUnlocked(0), isTrue);
    expect(memory.isUnlocked(1), isFalse);
    await memory.markPassed(0);
    expect(memory.isPassed(0), isTrue);
    expect(memory.isUnlocked(1), isTrue);
    expect(memory.isUnlocked(2), isFalse);

    final directory = Directory.systemTemp.createTempSync('sql-course');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/course.json');
    final stored = CourseProgress.file(file);
    await stored.markPassed(0);
    await stored.markPassed(1);
    final loaded = CourseProgress.file(file);
    await loaded.load();
    expect(loaded.isPassed(0), isTrue);
    expect(loaded.isPassed(1), isTrue);
    expect(loaded.isUnlocked(2), isTrue);
    expect(loaded.isUnlocked(3), isFalse);

    file.writeAsStringSync('{"unlocked": 4, "passed": [0, 1]}');
    final old = CourseProgress.file(file);
    await old.load();
    expect(old.isUnlocked(0), isTrue);
    expect(old.isUnlocked(1), isFalse);
    expect(old.passed, isEmpty);

    file.writeAsStringSync('{');
    final broken = CourseProgress.file(file);
    await broken.load();
    expect(broken.isUnlocked(0), isTrue);
    expect(broken.isUnlocked(1), isFalse);
    expect(broken.passed, isEmpty);
  });

  test('a step offers the tables its setup creates', () async {
    final objects = await lessonObjects(sqlCourse[0].tasks[0].setup);
    expect(objects.map((object) => object.name), ['books']);
    expect(objects.single.columns.map((column) => column.name), [
      'title',
      'pages',
    ]);
    expect(objects.single.columns.first.type, 'TEXT');
  });

  testWidgets('a lesson asks, checks one statement, and opens the next level', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = BrowserSession();
    final progress = CourseProgress.memory();
    await tester.pumpWidget(BrowserApp(session: session, course: progress));
    await _frames(tester);
    await tester.ensureVisible(find.byKey(const Key('home-learn')));
    await tester.tap(find.byKey(const Key('home-learn')));
    await _frames(tester);

    expect(find.textContaining('Twelve levels'), findsNothing);
    expect(
      tester.widget<InkWell>(find.byKey(const Key('course-level-1'))).onTap,
      isNull,
    );
    await tester.tap(find.byKey(const Key('course-level-0')));
    await _frames(tester);

    final lesson = sqlCourse[0];
    for (var part = 0; part < lesson.parts.length; part++) {
      final question = lesson.parts[part].question;
      if (part == 0) {
        final wrong = question.answer == 0 ? 1 : 0;
        await tester.ensureVisible(find.byKey(Key('mcq-choice-$wrong')));
        await tester.tap(find.byKey(Key('mcq-choice-$wrong')));
        await tester.pump();
        expect(_choiceFill(tester, wrong), _pickedFill);
        await tester.ensureVisible(find.byKey(const Key('mcq-next')));
        await tester.tap(find.byKey(const Key('mcq-next')));
        await _frames(tester);
        expect(_choiceFill(tester, wrong), _errorFill);
        expect(_choiceFill(tester, question.answer), _okFill);
        expect(find.byKey(const Key('course-retry')), findsOneWidget);
        expect(find.text(question.why), findsOneWidget);
        await tester.tap(find.byKey(const Key('course-retry')));
        await _frames(tester);
      }
      await tester
          .ensureVisible(find.byKey(Key('mcq-choice-${question.answer}')));
      await tester.tap(find.byKey(Key('mcq-choice-${question.answer}')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('mcq-next')));
      await tester.tap(find.byKey(const Key('mcq-next')));
      await _frames(tester);
      if (part < lesson.parts.length - 1) {
        await tester.tap(find.byKey(const Key('mcq-next')));
        await _frames(tester);
      }
    }
    await tester.tap(find.byKey(const Key('course-to-questions')));
    await _frames(tester);

    final questions = lesson.review;
    final first = questions.first;
    final wrong = first.answer == 0 ? 1 : 0;
    await tester.ensureVisible(find.byKey(Key('mcq-choice-$wrong')));
    await tester.tap(find.byKey(Key('mcq-choice-$wrong')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mcq-next')));
    await _frames(tester);
    expect(find.byKey(const Key('course-retry')), findsOneWidget);
    expect(find.text(first.why), findsOneWidget);
    expect(find.text(first.prompt), findsOneWidget);

    await tester.tap(find.byKey(const Key('course-retry')));
    await _frames(tester);

    for (var index = 0; index < questions.length; index++) {
      final question = questions[index];
      await tester.ensureVisible(
        find.byKey(Key('mcq-choice-${question.answer}')),
      );
      await tester.tap(find.byKey(Key('mcq-choice-${question.answer}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mcq-next')));
      await _frames(tester);
      if (index < questions.length - 1) {
        await tester.tap(find.byKey(const Key('mcq-next')));
        await _frames(tester);
      }
    }
    await tester.tap(find.byKey(const Key('course-to-sql')));
    await _frames(tester);

    await tester.enterText(find.byKey(const Key('task-sql')), 'SELECT ');
    await _until(tester, find.byKey(const Key('suggest-title')));
    expect(find.byKey(const Key('suggest-type-title')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('task-sql')), 'SELECT 1');
    await tester.tap(find.byKey(const Key('task-check')));
    await _until(tester, find.text('The result does not match.'));

    final tasks = sqlCourse[0].tasks;
    await tester.enterText(
        find.byKey(const Key('task-sql')), tasks[0].statement);
    await tester.tap(find.byKey(const Key('task-check')));
    await _until(tester, find.text('Passed'));

    for (var index = 1; index < tasks.length; index++) {
      await tester.tap(find.byKey(const Key('task-next')));
      await _frames(tester);
      expect(find.text('Passed'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('task-sql')),
        tasks[index].statement,
      );
      await tester.tap(find.byKey(const Key('task-check')));
      await _until(tester, find.text('Passed'));
    }
    await tester.tap(find.byKey(const Key('task-finish')));
    await _until(tester, find.byKey(const Key('course-next')));
    expect(progress.isPassed(0), isTrue);
    expect(progress.isUnlocked(1), isTrue);
    expect(progress.isUnlocked(2), isFalse);
    await tester.tap(find.byKey(const Key('course-next')));
    await _frames(tester);
    expect(find.text('Filtering rows'), findsOneWidget);
    expect(find.byKey(const Key('course-level-1')), findsNothing);
    await _finish(tester, session);
  });
}
