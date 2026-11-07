import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';

String _name(String name) => String.fromCharCodes(
    name.codeUnits.map((c) => c >= 65 && c <= 90 ? c + 32 : c));
Object? _copy(Object? value) =>
    value is Uint8List ? Uint8List.fromList(value) : value;
Object _canonical(Object? value) {
  if (value == null) return ['null'];
  if (value is int || value is BigInt) return ['integer', value.toString()];
  if (value is double) return ['real', value.toString()];
  if (value is Uint8List) return ['blob', base64Encode(value)];
  if (value is String) return ['text', value];
  if (value is bool) return ['boolean', value];
  throw ArgumentError('Expected SQL scalar value');
}

QueryResult _copyResult(QueryResult r) => QueryResult(
    r.columns,
    [
      for (final row in r.rows) [for (final value in row) _copy(value)]
    ],
    r.columnAffinities,
    r.columnDeclaredTypes,
    r.columnCollations);
String _signature(QueryResult r) => jsonEncode([
      r.columns,
      [for (final row in r.rows) row.map(_canonical).toList()]
    ]);

/// Null columns means every column. Structural changes always affect a table.
final class ReactiveInvalidation {
  ReactiveInvalidation(
      {Map<String, Set<String>?> tables = const {},
      Set<String> structural = const {},
      this.all = false})
      : tables = Map.unmodifiable({
          for (final e in tables.entries)
            _name(e.key): e.value == null
                ? null
                : Set<String>.unmodifiable(e.value!.map(_name))
        }),
        structural = Set.unmodifiable(structural.map(_name));
  final Map<String, Set<String>?> tables;
  final Set<String> structural;
  final bool all;
}

abstract interface class ReactiveInvalidationSource {
  Stream<ReactiveInvalidation> get events;
  Future<void> start();
  Future<void> flush();
  Future<void> stop();
}

enum ReactiveChangeKind { added, removed, updated, moved }

final class ReactiveRowChange {
  ReactiveRowChange(this.kind, Iterable<Object?> key,
      {this.index, this.previousIndex})
      : _key = List.unmodifiable(key.map(_copy));
  final ReactiveChangeKind kind;
  final List<Object?> _key;
  List<Object?> get key => List.unmodifiable(_key.map(_copy));
  final int? index, previousIndex;
}

final class ReactiveSnapshot<T> {
  ReactiveSnapshot(Iterable<T> items, Iterable<ReactiveRowChange> changes,
      {required this.revision, required this.isInitial})
      : items = List.unmodifiable(items),
        changes = List.unmodifiable(changes);
  final List<T> items;
  final List<ReactiveRowChange> changes;
  final int revision;
  final bool isInitial;
}

final class ReactiveLimitException implements Exception {
  const ReactiveLimitException(this.maximum);
  final int maximum;
  @override
  String toString() =>
      'ReactiveLimitException: retained row budget $maximum exceeded';
}

final class _Key {
  _Key(this.signature, this.scope);
  final String signature;
  final Object scope;
  @override
  int get hashCode => Object.hash(signature, identityHashCode(scope));
  @override
  bool operator ==(Object other) =>
      other is _Key &&
      signature == other.signature &&
      identical(scope, other.scope);
}

/// Lazy shared executions. evaluate must serialize with the owning writer.
/// Row factories run independently per subscriber, outside identity tracking.
final class ReactiveRegistry {
  ReactiveRegistry(
      {this.source, this.debounce = Duration.zero, this.maxRows = 10000}) {
    if (debounce.isNegative || maxRows < 1) {
      throw ArgumentError('Invalid debounce/row budget');
    }
  }
  final ReactiveInvalidationSource? source;
  final Duration debounce;
  final int maxRows;
  final _tasks = <_Key, _Task>{};
  final _defaultScope = Object();
  StreamSubscription<ReactiveInvalidation>? _sourceSubscription;
  Future<void>? _ready, _stopping;
  bool _closed = false;
  int get activeQueryCount => _tasks.length;
  bool get isClosed => _closed;

  ReactiveQuery<T> watch<T>(
      {required String sql,
      List<Object?> parameters = const [],
      required Map<String, Set<String>?> dependencies,
      required Future<QueryResult> Function() evaluate,
      required T Function(Map<String, Object?> row) decode,
      List<String> keyColumns = const [],
      Object? shareScope}) {
    final dep = {
      for (final e in dependencies.entries)
        _name(e.key): e.value == null
            ? null
            : Set<String>.unmodifiable(e.value!.map(_name))
    };
    if (dep.isEmpty || dep.keys.any((s) => s.isEmpty)) {
      throw ArgumentError('Declare query dependencies');
    }
    if (keyColumns.toSet().length != keyColumns.length) {
      throw ArgumentError('Duplicate key columns');
    }
    final depNames = dep.keys.toList()..sort();
    final sig = jsonEncode([
      sql,
      parameters.map(_canonical).toList(),
      keyColumns,
      [
        for (final n in depNames)
          [n, dep[n] == null ? null : (dep[n]!.toList()..sort())]
      ]
    ]);
    return ReactiveQuery._(this, _Key(sig, shareScope ?? _defaultScope),
        evaluate, decode, dep, List.unmodifiable(keyColumns));
  }

  Future<void> _ensureSource() async {
    if (source == null) return;
    if (_stopping != null) await _stopping;
    if (_closed) throw StateError('Reactive registry is closed');
    _sourceSubscription ??=
        source!.events.listen(invalidate, onError: (Object e, StackTrace s) {
      for (final task in _tasks.values.toList()) {
        task.error(e, s);
      }
    });
    final pending = _ready ??= source!.start();
    try {
      await pending;
    } catch (_) {
      if (identical(_ready, pending)) _ready = null;
      rethrow;
    }
  }

  void invalidate(ReactiveInvalidation change) {
    if (_closed) return;
    for (final task in _tasks.values.toList()) {
      if (task.affected(change)) task.schedule();
    }
  }

  Future<void> _release(_Task task) async {
    if (task.listeners.isNotEmpty) return;
    task.dispose();
    _tasks.remove(task.key);
    if (_tasks.isEmpty) await _stopSource();
  }

  Future<void> _stopSource() {
    final previous = _stopping;
    if (previous != null) return previous;
    final future = () async {
      final ready = _ready;
      _ready = null;
      if (ready != null) {
        try {
          await ready;
        } catch (_) {}
      }
      await _sourceSubscription?.cancel();
      _sourceSubscription = null;
      await source?.stop();
    }();
    _stopping = future;
    return future.whenComplete(() {
      if (identical(_stopping, future)) _stopping = null;
    });
  }

  /// Catch up the optional source, then complete queued evaluations.
  Future<void> flush() async {
    if (_closed) return;
    if (_tasks.isNotEmpty) {
      await _ensureSource();
      await source?.flush();
    }
    for (final task in _tasks.values.toList()) {
      await task.flush();
    }
    // Drain async StreamController delivery (including mapped count/any streams).
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final tasks = _tasks.values.toList();
    final closing = <Future<void>>[];
    _tasks.clear();
    for (final task in tasks) {
      task.dispose();
      for (final listener in task.listeners.toList()) {
        closing.add(listener.close());
      }
      task.listeners.clear();
      task.last = null;
    }
    // Do not wait for evaluator callbacks: an owner may close while holding
    // its own queue. In-flight results are discarded after disposal.
    await _stopSource();
    await Future.wait(closing);
  }
}

final class ReactiveQuery<T> extends Stream<ReactiveSnapshot<T>> {
  ReactiveQuery._(this._registry, this._key, this._evaluate, this._decode,
      this._deps, this._keys);
  final ReactiveRegistry _registry;
  final _Key _key;
  final Future<QueryResult> Function() _evaluate;
  final T Function(Map<String, Object?>) _decode;
  final Map<String, Set<String>?> _deps;
  final List<String> _keys;
  Future<void> refresh({bool force = false}) async {
    if (_registry.isClosed) throw StateError('Reactive registry is closed');
    final task = _registry._tasks[_key];
    if (task == null) return;
    task.schedule(force: force, immediate: true);
    await task.flush();
    await Future<void>.delayed(Duration.zero);
  }

  @override
  StreamSubscription<ReactiveSnapshot<T>> listen(
      void Function(ReactiveSnapshot<T>)? onData,
      {Function? onError,
      void Function()? onDone,
      bool? cancelOnError}) {
    if (_registry.isClosed) {
      return Stream<ReactiveSnapshot<T>>.error(
              StateError('Reactive registry is closed'))
          .listen(onData,
              onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    }
    final task = _registry._tasks.putIfAbsent(
        _key, () => _Task(_registry, _key, _evaluate, _deps, _keys));
    final listener = _Listener<T>(task, _decode);
    task.listeners.add(listener);
    final sub = listener.controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    if (task.last != null) {
      listener.deliver();
    } else {
      task.schedule(immediate: true);
    }
    return sub;
  }
}

abstract class _Subscription {
  void deliver();
  void error(Object e, StackTrace s);
  Future<void> close();
}

final class _Listener<T> implements _Subscription {
  _Listener(this.task, this.decode) {
    controller = StreamController<ReactiveSnapshot<T>>(
        onPause: () => paused = true,
        onResume: () {
          paused = false;
          final failure = pausedError;
          pausedError = null;
          if (failure != null) controller.addError(failure.$1, failure.$2);
          if (pending) deliver();
        },
        onCancel: () async {
          closed = true;
          previous = null;
          pausedError = null;
          task.listeners.remove(this);
          await task.owner._release(task);
        });
  }
  final _Task task;
  final T Function(Map<String, Object?>) decode;
  late final StreamController<ReactiveSnapshot<T>> controller;
  QueryResult? previous;
  (Object, StackTrace)? pausedError;
  int deliveredRevision = -1;
  bool paused = false, pending = false, closed = false;
  @override
  void deliver() {
    if (closed || task.last == null) return;
    if (paused) {
      pending = true;
      return;
    }
    if (deliveredRevision == task.revision) return;
    pending = false;
    try {
      final raw = task.last!;
      final copy = _copyResult(raw);
      final items = [
        for (final row in copy.rows)
          decode({
            for (var i = 0; i < copy.columns.length; i++)
              copy.columns[i]: row[i]
          })
      ];
      final changes = _diff(previous, raw, task.keys);
      controller.add(ReactiveSnapshot(items, changes,
          revision: task.revision, isInitial: previous == null));
      previous = raw;
      deliveredRevision = task.revision;
    } catch (e, s) {
      controller.addError(e, s);
    }
  }

  @override
  void error(Object e, StackTrace s) {
    if (closed) return;
    if (paused) {
      pausedError = (e, s);
      return;
    }
    controller.addError(e, s);
  }

  @override
  Future<void> close() {
    if (closed) return Future.value();
    closed = true;
    previous = null;
    pausedError = null;
    final done = controller.close();
    if (paused) {
      unawaited(done);
      return Future.value();
    }
    return done;
  }
}

final class _Task {
  _Task(this.owner, this.key, this.evaluate, this.deps, this.keys);
  final ReactiveRegistry owner;
  final _Key key;
  final Future<QueryResult> Function() evaluate;
  final Map<String, Set<String>?> deps;
  final List<String> keys;
  final listeners = <_Subscription>{};
  QueryResult? last;
  String? fingerprint;
  int revision = 0;
  bool dirty = false, force = false, disposed = false;
  Timer? timer;
  Future<void>? running;
  bool affected(ReactiveInvalidation change) {
    if (change.all || deps.containsKey('*')) return true;
    for (final dep in deps.entries) {
      if (change.structural.contains(dep.key)) return true;
      if (!change.tables.containsKey(dep.key)) continue;
      final columns = change.tables[dep.key];
      if (columns == null ||
          dep.value == null ||
          columns.any(dep.value!.contains)) {
        return true;
      }
    }
    return false;
  }

  void schedule({bool force = false, bool immediate = false}) {
    if (disposed) return;
    dirty = true;
    this.force |= force;
    if (running != null) return;
    timer?.cancel();
    timer = null;
    if (!immediate && last != null && owner.debounce > Duration.zero) {
      timer = Timer(owner.debounce, () => _start());
    } else {
      _start();
    }
  }

  void _start() {
    if (disposed || running != null) return;
    timer?.cancel();
    timer = null;
    final work = Future<void>.microtask(_pump);
    running = work.whenComplete(() {
      running = null;
      if (dirty && !disposed) schedule(immediate: true);
    });
  }

  Future<void> _pump() async {
    while (dirty && !disposed) {
      dirty = false;
      final forced = force;
      force = false;
      try {
        await owner._ensureSource();
        if (disposed) return;
        final result = await evaluate();
        if (disposed) return;
        if (result.rows.length > owner.maxRows) {
          throw ReactiveLimitException(owner.maxRows);
        }
        final raw = _copyResult(result);
        _keyed(raw,
            keys); // Validate stable, unique keys before storing any result.
        final sig = _signature(raw);
        if (last == null || sig != fingerprint || forced) {
          last = raw;
          fingerprint = sig;
          revision++;
          for (final listener in listeners.toList()) {
            listener.deliver();
          }
        }
      } catch (e, s) {
        if (!disposed) error(e, s);
      }
    }
  }

  void error(Object e, StackTrace s) {
    for (final listener in listeners.toList()) {
      listener.error(e, s);
    }
  }

  Future<void> flush() async {
    timer?.cancel();
    timer = null;
    if (dirty && running == null) _start();
    while (running != null) {
      await running;
    }
  }

  void dispose() {
    disposed = true;
    dirty = false;
    last = null;
    fingerprint = null;
    timer?.cancel();
    timer = null;
  }
}

Map<String, (int, List<Object?>)> _keyed(QueryResult rows, List<String> keys) {
  if (keys.isEmpty) return {};
  final positions = keys.map(rows.columns.indexOf).toList();
  if (positions.any((p) => p < 0)) {
    throw StateError('Key columns must be projected');
  }
  final result = <String, (int, List<Object?>)>{};
  for (var i = 0; i < rows.rows.length; i++) {
    final key = [for (final p in positions) rows.rows[i][p]];
    if (key.any((v) => v == null)) {
      throw StateError('Reactive keys cannot contain NULL');
    }
    final identity = jsonEncode(key.map(_canonical).toList());
    if (result.containsKey(identity)) {
      throw StateError('Reactive keys must be unique');
    }
    result[identity] = (i, key);
  }
  return result;
}

List<ReactiveRowChange> _diff(
    QueryResult? previous, QueryResult current, List<String> keys) {
  if (keys.isEmpty) return const [];
  final before = previous == null
      ? <String, (int, List<Object?>)>{}
      : _keyed(previous, keys);
  final after = _keyed(current, keys);
  final result = <ReactiveRowChange>[];
  for (final e in before.entries) {
    if (!after.containsKey(e.key)) {
      result.add(ReactiveRowChange(ReactiveChangeKind.removed, e.value.$2,
          previousIndex: e.value.$1));
    }
  }
  for (final e in after.entries) {
    final old = before[e.key];
    final now = e.value;
    if (old == null) {
      result.add(
          ReactiveRowChange(ReactiveChangeKind.added, now.$2, index: now.$1));
      continue;
    }
    if (jsonEncode(previous!.rows[old.$1].map(_canonical).toList()) !=
        jsonEncode(current.rows[now.$1].map(_canonical).toList())) {
      result.add(ReactiveRowChange(ReactiveChangeKind.updated, now.$2,
          index: now.$1, previousIndex: old.$1));
    }
    if (old.$1 != now.$1) {
      result.add(ReactiveRowChange(ReactiveChangeKind.moved, now.$2,
          index: now.$1, previousIndex: old.$1));
    }
  }
  return result;
}
