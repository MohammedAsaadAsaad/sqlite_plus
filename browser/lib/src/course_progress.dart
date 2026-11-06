import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'course_lessons.dart';

/// Which course levels are open. [file] is null in tests.
class CourseProgress extends ChangeNotifier {
  CourseProgress.memory() : file = null;

  CourseProgress.file(this.file);

  /// `course.json`, beside the recent-file list.
  final File? file;

  var unlocked = 0;
  final Set<int> passed = {};
  final Set<int> passedChapters = {};
  var _loaded = false;

  bool isUnlocked(int index) => index >= 0 && index <= unlocked;

  bool isPassed(int index) => passed.contains(index);

  bool isChapterPassed(int chapter) => passedChapters.contains(chapter);

  /// The chapter quiz opens once every lesson in it has passed.
  bool isChapterOpen(int chapter) {
    if (chapter < 0 || chapter >= sqlChapters.length) return false;
    final start = firstLessonOf(chapter);
    final count = sqlChapters[chapter].lessons.length;
    for (var index = 0; index < count; index++) {
      if (!isPassed(start + index)) return false;
    }
    return true;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final target = file;
    if (target == null || !target.existsSync()) return;
    try {
      _apply(jsonDecode(target.readAsStringSync()));
    } on FormatException {
      unlocked = 0;
      passed.clear();
    } on FileSystemException {
      unlocked = 0;
      passed.clear();
    }
    notifyListeners();
  }

  /// Records [index] and opens the following level.
  Future<void> markPassed(int index) async {
    if (index < 0 || index >= sqlCourse.length) return;
    passed.add(index);
    final next = index + 1;
    final sameChapter = next < sqlCourse.length &&
        chapterOfLesson(next) == chapterOfLesson(index);
    if (sameChapter && next > unlocked) unlocked = next;
    await _save();
    notifyListeners();
  }

  /// Records the chapter quiz and opens the next chapter.
  Future<void> markChapterPassed(int chapter) async {
    if (chapter < 0 || chapter >= sqlChapters.length) return;
    passedChapters.add(chapter);
    final next = chapter + 1;
    if (next < sqlChapters.length) {
      final first = firstLessonOf(next);
      if (first > unlocked) unlocked = first;
    }
    await _save();
    notifyListeners();
  }

  void _apply(Object? decoded) {
    if (decoded is! Map) return;
    if (decoded['version'] != 2) return;
    final unlockedValue = decoded['unlocked'];
    final passedValue = decoded['passed'];
    final chapterValue = decoded['chapters'];
    if (unlockedValue is! int ||
        passedValue is! List ||
        chapterValue is! List) {
      return;
    }
    final nextPassed = <int>{};
    for (final item in passedValue) {
      if (item is int && item >= 0 && item < sqlCourse.length) {
        nextPassed.add(item);
      }
    }
    var nextUnlocked = unlockedValue;
    if (nextUnlocked < 0) nextUnlocked = 0;
    if (nextUnlocked > sqlCourse.length - 1) {
      nextUnlocked = sqlCourse.length - 1;
    }
    final nextChapters = <int>{};
    for (final item in chapterValue) {
      if (item is int && item >= 0 && item < sqlChapters.length) {
        nextChapters.add(item);
      }
    }
    unlocked = nextUnlocked;
    passed
      ..clear()
      ..addAll(nextPassed);
    passedChapters
      ..clear()
      ..addAll(nextChapters);
  }

  Future<void> _save() async {
    final target = file;
    if (target == null) return;
    final parent = target.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final names = passed.toList()..sort();
    final chapters = passedChapters.toList()..sort();
    target.writeAsStringSync(
      jsonEncode({
        'version': 2,
        'unlocked': unlocked,
        'passed': names,
        'chapters': chapters,
      }),
    );
  }
}
