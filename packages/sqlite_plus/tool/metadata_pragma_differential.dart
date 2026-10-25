// Development-only runner for tool/verify_metadata_pragmas.py.
import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

final class _Aggregate extends SqlAggregate {
  @override
  void step(List<Object?> arguments) {}
  @override
  Object? finish() => BigInt.zero;
}

Object? _encode(Object? value) => value is BigInt
    ? {'integer': value.toString()}
    : value is List
        ? value.map(_encode).toList()
        : value;

Future<void> main(List<String> arguments) async {
  final input = jsonDecode(await File(arguments.single).readAsString()) as Map;
  final storage = MemoryStorageBackend();
  await storage.write(0, await File(input['image'] as String).readAsBytes());
  final functions = SqlFunctionRegistry();
  var calls = 0;
  functions.registerScalar('metadata_probe', 0, (_) {
    calls++;
    throw StateError('Metadata evaluated a callback');
  });
  functions.registerScalar('custom_scalar', 1, (_) => 0, deterministic: true);
  functions.registerScalar('custom_scalar', -1, (_) => 0);
  functions.registerAggregate('custom_aggregate', 2, _Aggregate.new);
  final db = await SqliteDatabase.openReadOnly(storage, functions: functions);
  try {
    final output = [];
    for (final sql in input['queries'] as List) {
      try {
        final result = await db.query(sql as String);
        output.add({'columns': result.columns, 'rows': _encode(result.rows)});
      } on SqlException {
        output.add({'error': true});
      }
    }
    if (calls != 0) throw StateError('Metadata invoked callbacks $calls times');
    stdout.write(jsonEncode(output));
  } finally {
    await db.close();
  }
}
