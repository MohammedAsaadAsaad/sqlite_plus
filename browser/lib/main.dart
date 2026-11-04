import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'browser_app.dart';
import 'src/course_progress.dart';
import 'src/launch_bridge.dart';
import 'src/linux_files.dart';
import 'src/recent_files.dart';
import 'src/session.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) await _registerLinux();
  final opened = Platform.isLinux ? await openedSqliteArgument(args) : null;
  final session = BrowserSession();
  final recents = await _recents();
  final course = await _course();
  runApp(
    BrowserApp(
      session: session,
      recents: recents,
      course: course,
      launch: opened?.file,
      launchMessage: opened?.message,
    ),
  );
}

Future<void> _registerLinux() async {
  try {
    final icon = await rootBundle.load('assets/app_icon.png');
    await installLinuxFileAssociation(
      executable: Platform.resolvedExecutable,
      icon: icon.buffer.asUint8List(icon.offsetInBytes, icon.lengthInBytes),
    );
  } on Object {
    // The database still opens when a desktop tool is missing.
  }
}

Future<RecentStore> _recents() async {
  try {
    final directory = await _browserDirectory();
    final store = RecentStore.directory(directory);
    await store.load();
    return store;
  } on Object {
    return RecentStore.memory();
  }
}

Future<CourseProgress> _course() async {
  try {
    final directory = await _browserDirectory();
    final progress = CourseProgress.file(
      File('${directory.path}/course.json'),
    );
    await progress.load();
    return progress;
  } on Object {
    return CourseProgress.memory();
  }
}

Future<Directory> _browserDirectory() async {
  if (Platform.isAndroid) {
    final path = await LaunchBridge.documents();
    if (path != null) return Directory('$path/sqlite-browser');
  }
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return Directory('$home${Platform.pathSeparator}.sqlite-browser');
}
