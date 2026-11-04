import 'dart:io';

import 'package:flutter/widgets.dart';

import 'browser_app.dart';
import 'src/course_progress.dart';
import 'src/graph_layout.dart';
import 'src/launch_bridge.dart';
import 'src/recent_files.dart';
import 'src/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = BrowserSession();
  final recents = await _recents();
  final course = await _course();
  final graphs = await _graphs();
  runApp(BrowserApp(
    session: session,
    recents: recents,
    course: course,
    graphs: graphs,
  ));
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

Future<GraphLayoutStore> _graphs() async {
  try {
    final directory = await _browserDirectory();
    final store = GraphLayoutStore.file(
      File('${directory.path}/graphs.json'),
    );
    await store.load();
    return store;
  } on Object {
    return GraphLayoutStore.memory();
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
