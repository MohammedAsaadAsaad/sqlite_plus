import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:vm_service/vm_service_io.dart';
import '../jobs_benchmark/main.dart' as benchmark;

Future<void> main(List<String> args) async {
  final info = await Service.getInfo();
  final server = info.serverUri;
  if (server == null) {
    throw StateError(
        'Run with --observe=0 --disable-service-auth-codes --profiler');
  }
  final client = await vmServiceConnectUri(
      server.replace(scheme: 'ws', path: '${server.path}ws').toString());
  try {
    final vm = await client.getVM();
    final isolate = vm.isolates!
        .firstWhere((i) => i.name == 'main', orElse: () => vm.isolates!.first);
    await client.clearCpuSamples(isolate.id!);
    await benchmark.main(['20', 'batch']);
    final samples = await client.getCpuSamples(isolate.id!, 0, 1 << 62);
    final functions = samples.functions!
      ..sort(
          (a, b) => (b.inclusiveTicks ?? 0).compareTo(a.inclusiveTicks ?? 0));
    final report = {
      'samples': samples.sampleCount,
      'functions': functions.take(60).map((f) => f.toJson()).toList()
    };
    await File('/tmp/jobs-cpu-profile.json').writeAsString(jsonEncode(report));
    for (final f in functions
        .where((f) => (f.resolvedUrl ?? '').contains('sqlite_plus'))
        .take(25)) {
      final raw = f.toJson()['function'] as Map;
      print(
          '${f.inclusiveTicks} / ${f.exclusiveTicks}: ${raw['name']} (${f.resolvedUrl})');
    }
  } finally {
    await client.dispose();
  }
}
