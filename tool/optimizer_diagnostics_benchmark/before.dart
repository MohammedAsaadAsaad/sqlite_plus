import 'workload.dart';

Future<void> main(List<String> args) =>
    workload(args, (db, sql, params, enabled, capacity) async {
      if (enabled) throw UnsupportedError('Baseline has no diagnostic API');
      return ReadSample(await ordinaryRead(db, sql, params));
    });
