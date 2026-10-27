import 'dart:io';

import 'package:sqlite_plus_generator_example/library_app.dart';

Future<void> main() async {
  final library = await runLibraryApp();
  stdout.writeln('${library.customer} bought ${library.totals}; '
      '${library.note}; ${library.article}; place ${library.placeId} '
      'of ${library.storedPlaces}');
}
