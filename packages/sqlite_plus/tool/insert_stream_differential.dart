import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

import 'export_schema.dart' show encode;

Future<void> main(List<String> arguments) async {
  final directory = Directory(arguments[0]);
  final encoding = int.parse(arguments[1]);
  final fixture =
      arguments.length > 2 ? arguments[2] : 'insert_stream_oracle.json';
  final oracle =
      jsonDecode(File('test/fixtures/$fixture').readAsStringSync()) as Map;
  final suite = (oracle['suites'] as List)
      .singleWhere((value) => value['encoding'] == encoding) as Map;
  final output = <Object?>[];
  for (final (index, scenario) in (suite['cases'] as List).indexed) {
    final db = await MutableSqliteDatabase.create(encoding: encoding);
    final trace = <String>[];
    var serial = 0;
    int increment(String name) {
      trace.add('$name:${++serial}');
      return serial;
    }

    Object? visit(String name, Object? value) {
      trace.add('$name:$value');
      return value;
    }

    db.functions.registerScalar('tick', 0, (_) => increment('tick'));
    db.functions.registerScalar('stamp', 0, (_) => increment('stamp'));
    db.functions.registerScalar('visit', 1, (args) => visit('visit', args[0]));
    db.functions.registerScalar('audit', 1, (args) => visit('audit', args[0]));
    db.functions.registerScalar(
        'keep', 1, (args) => visit('keep', args[0]) != BigInt.two ? 1 : 0);
    db.functions.registerScalar('gate', 2, (args) {
      trace.add('gate:${args[0]}:${args[1]}');
      return args[0] == args[1] ? 1 : 0;
    });
    db.functions.registerScalar('fail_if', 1, (args) {
      visit('fail_if', args[0]);
      if (args[0] == BigInt.two) {
        throw const SqlException('requested projection failure');
      }
      return args[0];
    });
    db.functions.registerScalar('bad_stamp', 0, (_) {
      trace.add('bad_stamp');
      throw const SqlException('requested default failure');
    });
    final steps = <Object?>[];
    try {
      for (final step in scenario['steps'] as List) {
        final sql = step['sql'] as String;
        final parameters = step['parameters'] as List;
        var error = false;
        var changes = 0;
        var rows = <List<Object?>>[];
        try {
          if (step['query'] == true) {
            rows = (await db.query(sql, parameters)).rows;
          } else {
            final mutation = await db.execute(sql, parameters);
            rows = mutation.returning?.rows ?? [];
            changes = mutation.changes;
          }
        } on SqlException {
          error = true;
        }
        steps.add({
          'error': error,
          'changes': changes,
          'rows': rows.map((row) => row.map(encode).toList()).toList(),
          'trace': List<String>.of(trace)
        });
      }
      File('${directory.path}/$index.db').writeAsBytesSync(db.exportImage());
      output.add(steps);
    } finally {
      await db.close();
    }
  }
  File('${directory.path}/observed.json').writeAsStringSync(jsonEncode(output));
}
