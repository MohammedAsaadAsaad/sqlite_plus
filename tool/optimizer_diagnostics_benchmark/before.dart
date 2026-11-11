import 'workload.dart';

Future<void> main(List<String> args) =>
    workload(args, (db, sql, params, enabled, capacity) async {
      if (enabled) throw UnsupportedError('Baseline has no diagnostic API');
      final clock = Stopwatch()..start();
      final result = await ordinaryRead(db, sql, params);
      clock.stop();
      return ReadSample(result, clock.elapsedMicroseconds);
    });
