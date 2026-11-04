import 'dart:io';

import 'package:sqlite_plus_geo_example/demos.dart';

Future<void> main() async {
  final demos = await runGeoDemos();
  stdout.writeln(
    '${demos.nearestName} | ${demos.zoneName} | ${demos.imported} | '
    '${demos.intersectionArea} | ${demos.indexed}',
  );
}
