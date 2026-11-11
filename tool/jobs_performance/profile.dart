import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:vm_service/vm_service_io.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';

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
    final db = await openInMemory();
    final jobs = await SqlitePlusJobs.open(
        database: db, clock: () => DateTime.utc(2026));
    final count = int.parse(args.firstOrNull ?? '1000');
    await jobs.transaction((tx) async {
      for (var i = 0; i < count; i++) {
        await tx.enqueue('upload',
            payload: {'n': i}, deduplicationKey: 'item$i');
      }
    });
    await client.clearCpuSamples(isolate.id!);
    for (var i = 0; i < 10; i++) {
      final lease = (await jobs.claim())!;
      await jobs.complete(lease);
    }

    final samples = await client.getCpuSamples(isolate.id!, 0, 1 << 62);
    final functions = samples.functions!
      ..sort(
          (a, b) => (b.inclusiveTicks ?? 0).compareTo(a.inclusiveTicks ?? 0));
    final report = {
      'samples': samples.sampleCount,
      'functions': functions.take(60).map((f) => f.toJson()).toList()
    };
    await File('/tmp/jobs-processing-profile.json')
        .writeAsString(jsonEncode(report));
    await db.close();
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
