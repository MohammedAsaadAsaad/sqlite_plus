import 'package:flutter/widgets.dart';

import 'browser_app.dart';
import 'src/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = BrowserSession();
  await session.openEmpty();
  runApp(BrowserApp(session: session));
}
