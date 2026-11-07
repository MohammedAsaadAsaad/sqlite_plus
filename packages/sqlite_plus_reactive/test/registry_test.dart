import 'dart:async';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_reactive/sqlite_plus_reactive.dart';
import 'package:test/test.dart';

void main() {
  test('lazy shared evaluation, filtering and latest paused snapshots',
      () async {
    final registry = ReactiveRegistry();
    addTearDown(registry.close);
    var calls = 0;
    var n = 1;
    ReactiveQuery<Map<String, Object?>> query() => registry.watch(
        sql: 'SELECT id,n FROM t',
        dependencies: {
          't': {'id', 'n'}
        },
        keyColumns: ['id'],
        evaluate: () async {
          calls++;
          return QueryResult([
            'id',
            'n'
          ], [
            [BigInt.one, BigInt.from(n)]
          ]);
        },
        decode: (r) => r);
    final watch = query();
    expect(calls, 0);
    final a = <ReactiveSnapshot<Map<String, Object?>>>[],
        b = <ReactiveSnapshot<Map<String, Object?>>>[];
    final first = watch.listen(a.add);
    final second = query().listen(b.add);
    await registry.flush();
    expect(calls, 1);
    expect(a.single.items.single['n'], BigInt.one);
    expect(b.length, 1);
    registry.invalidate(ReactiveInvalidation(tables: {'other': null}));
    registry.invalidate(ReactiveInvalidation(tables: {
      't': {'irrelevant'}
    }));
    await registry.flush();
    expect(calls, 1);
    second.pause();
    for (var i = 2; i <= 4; i++) {
      n = i;
      registry.invalidate(ReactiveInvalidation(tables: {
        't': {'n'}
      }));
      await registry.flush();
    }
    expect(a.last.items.single['n'], BigInt.from(4));
    expect(b.length, 1);
    second.resume();
    await Future<void>.delayed(Duration.zero);
    expect(b.length, 2);
    expect(b.last.items.single['n'], BigInt.from(4));
    expect(b.last.changes.single.kind, ReactiveChangeKind.updated);
    await first.cancel();
    expect(registry.activeQueryCount, 1);
    await second.cancel();
    expect(registry.activeQueryCount, 0);
  });

  test(
      'coalesces invalidations while evaluation runs and emits only differences',
      () async {
    final registry = ReactiveRegistry();
    addTearDown(registry.close);
    var calls = 0;
    final gate = Completer<void>();
    var n = 1;
    final query = registry.watch<int>(
        sql: 'x',
        dependencies: {'t': null},
        keyColumns: ['id'],
        evaluate: () async {
          calls++;
          final value = n;
          if (calls == 1) await gate.future;
          return QueryResult([
            'id'
          ], [
            [value]
          ]);
        },
        decode: (r) => (r['id'] as int));
    final values = <int>[];
    final sub = query.listen((s) => values.add(s.items.single));
    await Future<void>.delayed(Duration.zero);
    n = 2;
    for (var i = 0; i < 100; i++) {
      registry.invalidate(ReactiveInvalidation(all: true));
    }
    gate.complete();
    await registry.flush();
    expect(calls, 2);
    expect(values, [1, 2]);
    await query.refresh();
    expect(calls, 3);
    expect(values, [1, 2]);
    await sub.cancel();
  });

  test(
      'diffs additions removals and moves; caller mutation cannot alter retained rows',
      () async {
    final registry = ReactiveRegistry();
    addTearDown(registry.close);
    var rows = <List<Object?>>[
      [
        1,
        Uint8List.fromList([1])
      ],
      [
        2,
        Uint8List.fromList([2])
      ]
    ];
    final q = registry.watch<Map<String, Object?>>(
        sql: 'diff',
        dependencies: {'t': null},
        keyColumns: ['id'],
        evaluate: () async => QueryResult(['id', 'blob'], rows),
        decode: (r) => r);
    final events = <ReactiveSnapshot<Map<String, Object?>>>[];
    final sub = q.listen(events.add);
    await registry.flush();
    (events.single.items.first['blob'] as Uint8List)[0] = 9;
    await q.refresh();
    expect(events.length, 1);
    rows = [
      [
        2,
        Uint8List.fromList([2])
      ],
      [
        3,
        Uint8List.fromList([3])
      ]
    ];
    registry.invalidate(ReactiveInvalidation(all: true));
    await registry.flush();
    expect(events.last.changes.map((c) => c.kind).toSet(), {
      ReactiveChangeKind.removed,
      ReactiveChangeKind.moved,
      ReactiveChangeKind.added
    });
    await sub.cancel();
  });

  test(
      'error budgets and duplicate keys are recoverable; close discards in-flight work',
      () async {
    final registry = ReactiveRegistry(maxRows: 1);
    var large = true;
    final errors = <Object>[];
    final values = <int>[];
    final q = registry.watch<int>(
        sql: 'budget',
        dependencies: {'t': null},
        keyColumns: ['id'],
        evaluate: () async => QueryResult(
            ['id'],
            large
                ? [
                    [1],
                    [2]
                  ]
                : [
                    [1]
                  ]),
        decode: (r) => r['id'] as int);
    final sub =
        q.listen((s) => values.add(s.items.single), onError: errors.add);
    await registry.flush();
    expect(errors.single, isA<ReactiveLimitException>());
    large = false;
    await q.refresh();
    expect(values, [1]);
    await registry.close();
    expect(registry.activeQueryCount, 0);
    await sub.cancel();
    final gate = Completer<QueryResult>();
    final second = ReactiveRegistry();
    final s = second
        .watch<int>(
            sql: 'late',
            dependencies: {'t': null},
            evaluate: () => gate.future,
            decode: (r) => 0)
        .listen((_) => fail('late delivery'));
    await Future<void>.delayed(Duration.zero);
    await second.close();
    gate.complete(QueryResult([], []));
    await s.cancel();
  });

  test(
      'duplicate/null/missing keys and query failures surface as stream errors',
      () async {
    for (final kind in ['duplicate', 'null', 'missing', 'sql']) {
      final registry = ReactiveRegistry();
      final errors = <Object>[];
      final q = registry.watch<int>(
          sql: kind,
          dependencies: {'t': null},
          keyColumns: ['id'],
          evaluate: () async {
            if (kind == 'sql') throw StateError('query');
            return kind == 'missing'
                ? QueryResult([
                    'n'
                  ], [
                    [1]
                  ])
                : QueryResult(
                    ['id'],
                    kind == 'null'
                        ? [
                            [null]
                          ]
                        : [
                            [1],
                            [1]
                          ]);
          },
          decode: (r) => 0);
      final sub = q.listen((_) => fail('invalid key'), onError: errors.add);
      await registry.flush();
      expect(errors.length, 1);
      await sub.cancel();
      await registry.close();
    }
  });
}
