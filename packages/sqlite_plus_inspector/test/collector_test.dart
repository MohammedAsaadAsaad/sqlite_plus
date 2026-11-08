import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:test/test.dart';

Future<int> call(SqlInspector inspector, String sql,
        [List<Object?> args = const []]) =>
    inspector.measure(sql, args, InspectorOperation.query, () async => 7,
        rows: (_) => 1);

void main() {
  test(
      'redacts SQL literals/binds/comments, groups shape and retains no result data',
      () async {
    final inspector =
        SqlInspector(options: InspectorOptions(slowThreshold: Duration.zero));
    await call(
        inspector,
        "select name from people where id=42 and password='secret' -- private comment",
        [
          'bound-secret',
          Uint8List.fromList([1, 2]),
          BigInt.one
        ]);
    await call(
        inspector,
        "SELECT name FROM people WHERE id=99 AND password='different'",
        ['other']);
    final report = inspector.snapshot();
    expect(report.statementCount, 2);
    expect(report.slowCount, 2);
    expect(report.groups.single.count, 2);
    expect(report.records.first.rowCount, 1);
    expect(report.records.first.parameters,
        ['<text:12 chars>', '<blob:2 bytes>', '<integer>']);
    final json = report.toJsonString();
    for (final secret in [
      'secret',
      'different',
      'bound-secret',
      'private comment'
    ]) {
      expect(json, isNot(contains(secret)));
    }
    expect(jsonDecode(json), isA<Map>());
    expect(() => report.records.clear(), throwsUnsupportedError);
  });

  test(
      'explicit previews are bounded, and input mutation does not change records',
      () async {
    final inspector = SqlInspector(
        options: InspectorOptions(
            captureParameters: true, maxParameters: 2, maxValueChars: 4));
    final blob = Uint8List.fromList([1, 2, 3]);
    final args = <Object?>['abcdef', blob, BigInt.one];
    await call(inspector, 'SELECT ?,?,?', args);
    args.clear();
    blob[0] = 9;
    final record = inspector.snapshot().records.single;
    expect(record.parameterCount, 3);
    expect(record.parameters, ['"abc…"', '<blob:3 bytes>']);
    expect(inspector.snapshot().toJsonString(), isNot(contains('abcdef')));
  });

  test(
      'disabled/closed collectors return original futures and preserve errors/stacks',
      () async {
    final inspector = SqlInspector(enabled: false);
    final result = Future<int>.value(12);
    expect(
        identical(
            inspector.measure(
                'bad', [], InspectorOperation.query, () => result),
            result),
        isTrue);
    expect(await result, 12);
    expect(inspector.snapshot().statementCount, 0);
    inspector.enabled = true;
    final error = StateError('private-error-message');
    final stack = StackTrace.fromString('original-stack');
    try {
      await inspector.measure('SELECT ?', [], InspectorOperation.query,
          () => Future<int>.error(error, stack));
      fail('must fail');
    } catch (e, s) {
      expect(identical(e, error), isTrue);
      expect(s.toString(), contains('original-stack'));
    }
    expect(inspector.snapshot().failures, 1);
    expect(inspector.snapshot().toJsonString(),
        isNot(contains('private-error-message')));
    inspector.close();
    expect(await call(inspector, 'SELECT 3'), 7);
    expect(inspector.snapshot().statementCount, 1);
    expect(() => inspector.enabled = true, throwsStateError);
  });

  test('nested/concurrent scopes are isolated and report repeated-read hints',
      () async {
    final inspector =
        SqlInspector(options: InspectorOptions(repeatedReadThreshold: 2));
    await inspector.scope('outer', () async {
      await call(inspector, 'SELECT 1');
      await Future.wait([
        inspector.scope('a', () async {
          await call(inspector, 'SELECT id FROM t WHERE id=?', [1]);
          await call(inspector, 'SELECT id FROM t WHERE id=?', [2]);
        }),
        inspector.scope('b', () async {
          await call(inspector, 'SELECT id FROM t WHERE id=?', [3]);
        }),
      ]);
    });
    final scopes = {
      for (final scope in inspector.snapshot().scopes) scope.name: scope
    };
    expect(scopes['outer']!.queryCount, 4);
    expect(scopes['a']!.queryCount, 2);
    expect(scopes['b']!.queryCount, 1);
    expect(scopes['a']!.repeatedReads.single.count, 2);
    expect(scopes['b']!.repeatedReads, isEmpty);
    expect(scopes['a']!.parentId, scopes['outer']!.id);
    expect(scopes['outer']!.parentId, isNull);
  });

  test(
      'errors preserve failed scopes and late child work is not attributed to ended scopes',
      () async {
    final inspector = SqlInspector();
    final gate = Completer<void>();
    late Future<void> child;
    final error = StateError('failure');
    await expectLater(
        inspector.scope<void>('failed', () async {
          child = gate.future.then((_) async {
            await call(inspector, 'SELECT 1');
          });
          throw error;
        }),
        throwsA(same(error)));
    expect(inspector.snapshot().scopes.single.success, isFalse);
    gate.complete();
    await child;
    final report = inspector.snapshot();
    expect(report.scopes.single.queryCount, 0);
    expect(report.records.single.scopeId, isNull);
  });

  test(
      'records/groups/scopes evict and zero limits keep only aggregate counters',
      () async {
    final inspector = SqlInspector(
        options: InspectorOptions(maxRecords: 2, maxGroups: 1, maxScopes: 1));
    for (final name in ['a', 'b', 'c']) {
      await inspector.scope(name, () => call(inspector, 'SELECT $name FROM t'));
    }
    final report = inspector.snapshot();
    expect(report.records.length, 2);
    expect(report.groups.length, 1);
    expect(report.scopes.length, 1);
    expect(report.statementCount, 3);
    expect(report.droppedRecords, 1);
    expect(report.droppedGroups, 2);
    expect(report.droppedScopes, 2);
    final zero = SqlInspector(
        options: InspectorOptions(maxRecords: 0, maxGroups: 0, maxScopes: 0));
    await zero.scope('zero', () => call(zero, 'SELECT 1'));
    expect(zero.snapshot().statementCount, 1);
    expect(zero.snapshot().records, isEmpty);
    expect(zero.snapshot().groups, isEmpty);
    expect(zero.snapshot().scopes, isEmpty);
  });

  test(
      'clear discards in-flight history and metadata callbacks cannot fail successful SQL',
      () async {
    final inspector = SqlInspector();
    final gate = Completer<int>();
    final pending = inspector.measure(
        'SELECT 1', [], InspectorOperation.query, () => gate.future);
    inspector.clear();
    gate.complete(1);
    expect(await pending, 1);
    expect(inspector.snapshot().statementCount, 0);
    expect(
        await inspector.measure(
            'SELECT 2', [], InspectorOperation.query, () async => 2,
            rows: (_) => throw StateError('metadata')),
        2);
    expect(inspector.snapshot().failures, 0);
    expect(inspector.snapshot().diagnosticErrors, 1);
  });

  test('connection identities separate equivalent SQL and labels truncate',
      () async {
    final inspector = SqlInspector(options: InspectorOptions(maxLabelChars: 3));
    final a = inspector.connection('same'), b = inspector.connection('same');
    for (final c in [a, b]) {
      await inspector.measure(
          'SELECT 1', [], InspectorOperation.query, () async => 1,
          connection: c);
    }
    expect(inspector.snapshot().groups.length, 2);
    expect(inspector.snapshot().records.first.connectionLabel, 'sa…');
    expect(
        () => inspector.measure(
            'SELECT 1', [], InspectorOperation.query, () async => 1,
            connection: SqlInspector().connection('foreign')),
        throwsArgumentError);
  });

  test(
      'malformed/oversized SQL stays private, fingerprints do not collide at display cutoff',
      () async {
    final inspector = SqlInspector(
        options: InspectorOptions(maxSqlChars: 8, maxAnalysisChars: 64));
    await call(inspector, "SELECT 'unfinished-secret");
    await call(inspector, 'SELECT ${'sensitive' * 12}');
    await call(inspector, 'SELECT firstColumn FROM t');
    await call(inspector, 'SELECT anotherColumn FROM t');
    final report = inspector.snapshot();
    expect(report.groups.length, 4);
    expect(report.records.take(2).every((r) => !r.analyzed), isTrue);
    expect(report.toJsonString(), isNot(contains('sensitive')));
    expect(report.toJsonString(), isNot(contains('unfinished-secret')));
    expect(report.records.every((r) => r.sql.length <= 8), isTrue);
  });

  test('scope depth/active budgets bypass safely and configuration is checked',
      () async {
    final inspector = SqlInspector(
        options: InspectorOptions(maxScopeDepth: 1, maxActiveScopes: 1));
    expect(
        await inspector.scope(
            'a', () => inspector.scope('b', () => call(inspector, 'SELECT 1'))),
        7);
    expect(inspector.snapshot().scopes.length, 1);
    expect(inspector.snapshot().droppedScopes, 1);
    expect(inspector.snapshot().scopes.single.queryCount, 1);
    for (final create in [
      () => InspectorOptions(maxRecords: -1),
      () => InspectorOptions(maxGroups: 10001),
      () => InspectorOptions(maxScopeDepth: 0),
      () => InspectorOptions(maxSqlChars: 0),
      () => InspectorOptions(slowThreshold: const Duration(microseconds: -1)),
      () => InspectorOptions(repeatedReadThreshold: 1)
    ]) {
      expect(create, throwsArgumentError);
    }
  });
  test(
      'in-flight budget bypasses observation without blocking or changing work',
      () async {
    final inspector = SqlInspector(options: InspectorOptions(maxInFlight: 1));
    final gate = Completer<int>();
    final pending = inspector.measure(
        'SELECT 1', [], InspectorOperation.query, () => gate.future);
    final immediate = Future<int>.value(2);
    final bypassed = inspector.measure(
        'SELECT 2', [], InspectorOperation.query, () => immediate);
    expect(identical(immediate, bypassed), isTrue);
    expect(await bypassed, 2);
    expect(inspector.snapshot().skippedMeasurements, 1);
    gate.complete(1);
    expect(await pending, 1);
    expect(inspector.snapshot().statementCount, 1);
    await call(inspector, 'SELECT 3');
    expect(inspector.snapshot().statementCount, 2);
  });

  test('a new scope started by detached work has no ended parent', () async {
    final inspector = SqlInspector();
    final gate = Completer<void>();
    late Future<void> child;
    await inspector.scope('parent', () async {
      child = gate.future.then((_) => inspector.scope('late', () async {
            await call(inspector, 'SELECT 1');
          }));
    });
    gate.complete();
    await child;
    final late = inspector.snapshot().scopes.last;
    expect(late.name, 'late');
    expect(late.parentId, isNull);
    expect(late.queryCount, 1);
  });
  test('unquoted non-ASCII identifiers keep SQLite case distinctions',
      () async {
    final inspector = SqlInspector();
    await call(inspector, 'SELECT ä FROM t');
    await call(inspector, 'SELECT Ä FROM t');
    expect(inspector.snapshot().groups.length, 2);
  });
}
