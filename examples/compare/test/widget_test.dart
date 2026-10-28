import 'dart:async';

import 'package:engine_bench/app.dart';
import 'package:engine_bench/bench_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rejects a count outside 1 through 10000', (tester) async {
    await _tall(tester);
    final engine = ScriptedEngine(id: 'sqlite_plus', label: 'sqlite_plus');
    await tester.pumpWidget(
      BenchApp(engines: [engine], isolateSqlitePlus: false),
    );
    await tester.pump();

    Future<void> reject(String text) async {
      await tester.enterText(find.byKey(const Key('count-field')), text);
      await tester.tap(find.byKey(const Key('op-separateInsert')));
      await tester.pump();
      expect(find.text('Enter a count from 1 to 10000'), findsOneWidget);
      expect(find.byKey(const Key('log-line')), findsNothing);
      expect(engine.calls, 0);
    }

    await reject('0');
    await reject('10001');
    await reject('1.5');
    await reject('');
  });

  testWidgets('a run writes the log and a matching comparison', (tester) async {
    await _tall(tester);
    final native = ScriptedEngine(
      id: 'native',
      label: 'native',
      location: '/tmp/bench-native.db',
      elapsedMicros: 4000,
    );
    final plus = ScriptedEngine(
      id: 'sqlite_plus',
      label: 'sqlite_plus',
      elapsedMicros: 2000,
    );
    await tester.pumpWidget(
      BenchApp(engines: [native, plus], isolateSqlitePlus: false),
    );
    await tester.pump();
    expect(find.text('Bench'), findsOneWidget);
    expect(find.text('Native file'), findsOneWidget);
    expect(find.text('/tmp/bench-native.db'), findsOneWidget);
    expect(find.byKey(const Key('live-rss')), findsOneWidget);
    expect(find.byKey(const Key('live-cpu')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('count-field')), '5');
    await tester.tap(find.byKey(const Key('op-search')));
    await _flush(tester);

    expect(find.byKey(const Key('log-line')), findsNWidgets(2));
    expect(find.byKey(const Key('compare-search')), findsOneWidget);
    expect(find.text('Match'), findsOneWidget);
    expect(find.text('sqlite_plus / native  0.50'), findsOneWidget);
    expect(native.calls, 1);
    expect(plus.calls, 1);
    expect(plus.counts.single, 5);

    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final arguments = call.arguments as Map<Object?, Object?>;
        clipboard = arguments['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clipboard};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.tap(find.byKey(const Key('copy-log')));
    await tester.pump();
    final copied = await Clipboard.getData(Clipboard.kTextPlain);
    expect(copied?.text, contains('Search  count=5'));
    expect(copied?.text, contains('sqlite_plus / native 0.50'));
    expect(copied?.text, contains('match'));
    expect(find.text('Log copied'), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear-log')));
    await tester.pump();
    expect(find.text('Log empty'), findsOneWidget);
    expect(find.byKey(const Key('compare-search')), findsNothing);
  });

  testWidgets('different checksums stay visible in the comparison', (
    tester,
  ) async {
    await _tall(tester);
    await tester.pumpWidget(
      BenchApp(
        engines: [
          ScriptedEngine(id: 'native', label: 'native', checksum: 1),
          ScriptedEngine(id: 'sqlite_plus', label: 'sqlite_plus', checksum: 2),
        ],
        isolateSqlitePlus: false,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('count-field')), '5');
    await tester.tap(find.byKey(const Key('op-point')));
    await _flush(tester);
    expect(find.text('Different'), findsOneWidget);
  });

  testWidgets('a failed engine is logged and the other engine still runs', (
    tester,
  ) async {
    await _tall(tester);
    await tester.pumpWidget(
      BenchApp(
        engines: [
          ScriptedEngine(
            id: 'native',
            label: 'native',
            error: StateError('broken'),
          ),
          ScriptedEngine(id: 'sqlite_plus', label: 'sqlite_plus'),
        ],
        isolateSqlitePlus: false,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('count-field')), '5');
    await tester.tap(find.byKey(const Key('op-deleteAll')));
    await _flush(tester);
    expect(find.textContaining('broken'), findsWidgets);
    expect(find.byKey(const Key('log-line')), findsNWidgets(2));
  });

  testWidgets(
    'buttons stay quiet while a run is in progress and metrics remain',
    (tester) async {
      await _tall(tester);
      final gate = Completer<void>();
      final engine = ScriptedEngine(
        id: 'sqlite_plus',
        label: 'sqlite_plus',
        gate: gate,
      );
      await tester.pumpWidget(
        BenchApp(engines: [engine], isolateSqlitePlus: false),
      );
      await tester.pump();
      await tester.enterText(find.byKey(const Key('count-field')), '5');
      await tester.tap(find.byKey(const Key('op-separateInsert')));
      await tester.pump();

      expect(engine.calls, 1);
      expect(find.byKey(const Key('progress')), findsOneWidget);
      expect(find.byKey(const Key('live-rss')), findsOneWidget);
      final insert = tester.widget<OutlinedButton>(
        find.byKey(const Key('op-separateInsert')),
      );
      final all = tester.widget<FilledButton>(find.byKey(const Key('run-all')));
      expect(insert.onPressed, isNull);
      expect(all.onPressed, isNull);

      await tester.tap(find.byKey(const Key('op-transactionInsert')));
      await tester.pump();
      expect(engine.calls, 1);

      gate.complete();
      await _flush(tester);
      expect(find.byKey(const Key('log-line')), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('op-separateInsert')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('run all records every operation for every engine', (
    tester,
  ) async {
    await _tall(tester);
    await tester.pumpWidget(
      BenchApp(
        engines: [
          ScriptedEngine(id: 'native', label: 'native'),
          ScriptedEngine(id: 'sqlite_plus', label: 'sqlite_plus'),
        ],
        isolateSqlitePlus: false,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('count-field')), '2');
    await tester.tap(find.byKey(const Key('run-all')));
    await _flush(tester);
    expect(
      find.byKey(const Key('log-line')),
      findsNWidgets(BenchOp.values.length * 2),
    );
    expect(find.byKey(const Key('compare-separateInsert')), findsOneWidget);
    expect(find.byKey(const Key('compare-deleteAll')), findsOneWidget);
    expect(find.byKey(const Key('compare-vacuum')), findsOneWidget);
  });
}

Future<void> _tall(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 8000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (find.byKey(const Key('progress')).evaluate().isEmpty &&
        find.byKey(const Key('log-line')).evaluate().isNotEmpty) {
      return;
    }
  }
}

class ScriptedEngine implements BenchEngine {
  ScriptedEngine({
    required this.id,
    required this.label,
    this.location,
    this.elapsedMicros = 1000,
    this.checksum = 10,
    this.gate,
    this.error,
  });

  @override
  final String id;
  @override
  final String label;
  @override
  final String? location;
  final int elapsedMicros;
  final int checksum;
  final Completer<void>? gate;
  final Object? error;
  var calls = 0;
  final counts = <int>[];

  @override
  Future<BenchSample> run(
    BenchOp op,
    int count,
    void Function(int done, int total) onProgress,
  ) async {
    calls += 1;
    counts.add(count);
    onProgress(0, count);
    onProgress(count, count);
    final gate = this.gate;
    if (gate != null) await gate.future;
    final error = this.error;
    if (error != null) throw error;
    return BenchSample(
      engineId: id,
      engineLabel: label,
      op: op,
      count: count,
      elapsedMicros: elapsedMicros,
      cpuMicros: 20,
      rssBefore: 1000,
      rssAfter: 1200,
      rows: count,
      checksum: checksum,
      hits: count,
      prepareMicros: 30,
      exportMicros: id == 'sqlite_plus' ? 40 : 0,
      storedBytes: 4096,
    );
  }
}
