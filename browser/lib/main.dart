import 'dart:io';

import 'package:flutter/widgets.dart';

import 'browser_app.dart';
import 'src/launch_bridge.dart';
import 'src/recent_files.dart';
import 'src/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = BrowserSession();
  final recents = await _recents();
  runApp(BrowserApp(session: session, recents: recents));
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
