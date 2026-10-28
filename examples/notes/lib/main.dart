import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'note_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await getApplicationDocumentsDirectory();
  final store = NoteStore(directory);
  await store.open();
  runApp(MarginApp(store: store));
}
