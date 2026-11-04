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
  var _loaded = false;

  bool isUnlocked(int index) => index >= 0 && index <= unlocked;

  bool isPassed(int index) => passed.contains(index);

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
    if (next > unlocked) {
      unlocked = next >= sqlCourse.length ? sqlCourse.length - 1 : next;
    }
    await _save();
    notifyListeners();
  }

  void _apply(Object? decoded) {
    if (decoded is! Map) return;
    final unlockedValue = decoded['unlocked'];
    final passedValue = decoded['passed'];
    if (unlockedValue is! int || passedValue is! List) return;
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
    unlocked = nextUnlocked;
    passed
      ..clear()
      ..addAll(nextPassed);
  }

  Future<void> _save() async {
    final target = file;
    if (target == null) return;
    final parent = target.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final names = passed.toList()..sort();
    target.writeAsStringSync(
      jsonEncode({'unlocked': unlocked, 'passed': names}),
    );
  }
}
