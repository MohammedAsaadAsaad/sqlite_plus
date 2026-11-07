import 'dart:async';
import 'dart:typed_data';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'registry.dart';

/// Stateless current-result observation. Never owns a durable retention consumer.
final class ChangesReactiveSource implements ReactiveInvalidationSource {
  ChangesReactiveSource(this.changes,
      {this.maxTransactions = 1000,
      this.maxEvents = 100000,
      this.maxPages = 16}) {
    if (maxTransactions < 1 ||
        maxTransactions > 1000 ||
        maxEvents < 1 ||
        maxEvents > 1000000 ||
        maxPages < 1) {
      throw ArgumentError('Invalid reactive log budgets');
    }
  }
  final int maxTransactions, maxEvents, maxPages;
  final SqlitePlusChanges changes;
  final _events = StreamController<ReactiveInvalidation>.broadcast(sync: true);
  StreamSubscription<ChangeNotification>? _subscription;
  ChangeCheckpoint? _cursor;
  Future<void>? _ready, _working;
  bool _active = false, _pending = false, _reset = false;
  @override
  Stream<ReactiveInvalidation> get events => _events.stream;
  @override
  Future<void> start() {
    if (_ready != null) return _ready!;
    _active = true;
    _subscription = changes.commits.listen((signal) {
      _pending = true;
      _reset |= signal.reset;
      _schedule();
    });
    final ready = () async {
      try {
        _cursor = await changes.head();
      } catch (_) {
        _active = false;
        await _subscription?.cancel();
        _subscription = null;
        _ready = null;
        rethrow;
      }
    }();
    _ready = ready;
    return ready;
  }

  void _schedule() {
    if (!_active || _working != null) return;
    final work = Future<void>.microtask(() async {
      await _ready;
      while (_pending && _active) {
        _pending = false;
        if (_reset) {
          _reset = false;
          _cursor = await changes.head();
          if (_active) _events.add(ReactiveInvalidation(all: true));
          continue;
        }
        try {
          var more = true;
          var pages = 0;
          final target = await changes.head();
          final tables = <String, Set<String>?>{};
          final structural = <String>{};
          while (more && _active) {
            if (++pages > maxPages) {
              _cursor = await changes.head();
              if (_active) _events.add(ReactiveInvalidation(all: true));
              tables.clear();
              break;
            }
            final batch = await changes.readSince(_cursor!,
                maxTransactions: maxTransactions, maxEvents: maxEvents);
            _cursor = batch.checkpoint;
            for (final event in batch.events) {
              tables
                  .putIfAbsent(event.table, () => <String>{})!
                  .addAll(event.changedColumns);
              if (event.kind != ChangeKind.update) structural.add(event.table);
            }
            if (target.feedId != _cursor!.feedId) {
              _cursor = await changes.head();
              if (_active) _events.add(ReactiveInvalidation(all: true));
              tables.clear();
              break;
            }
            more = target.batch > _cursor!.batch;
          }
          if (_active && tables.isNotEmpty) {
            _events.add(
                ReactiveInvalidation(tables: tables, structural: structural));
          }
        } on CheckpointExpired {
          _cursor = await changes.head();
          if (_active) _events.add(ReactiveInvalidation(all: true));
        } on ChangeBatchTooLarge {
          _cursor = await changes.head();
          if (_active) _events.add(ReactiveInvalidation(all: true));
        } on ArgumentError {
          final head = await changes.head();
          if (head.feedId == _cursor?.feedId) rethrow;
          _cursor = head;
          if (_active) _events.add(ReactiveInvalidation(all: true));
        }
      }
    });
    _working = work.catchError((Object e, StackTrace s) {
      if (_active) _events.addError(e, s);
    }).whenComplete(() {
      _working = null;
      if (_pending && _active) _schedule();
    });
  }

  @override
  Future<void> flush() async {
    await start();
    _pending = true;
    _schedule();
    while (_working != null) {
      await _working;
    }
  }

  @override
  Future<void> stop() async {
    _active = false;
    _pending = false;
    _reset = false;
    await _subscription?.cancel();
    _subscription = null;
    final work = _working;
    if (work != null) await work;
    _ready = null;
    _cursor = null;
  }
}

/// SQL entry point for applications without ORM. Dependencies are explicit;
/// use ORM watch APIs when typed metadata should infer them automatically.
final class ReactiveDatabase {
  ReactiveDatabase(this.changes,
      {Duration debounce = Duration.zero, int maxRows = 10000})
      : registry = ReactiveRegistry(
            source: ChangesReactiveSource(changes),
            debounce: debounce,
            maxRows: maxRows);
  final SqlitePlusChanges changes;
  final ReactiveRegistry registry;
  ReactiveQuery<Map<String, Object?>> watch(String sql,
      {List<Object?> parameters = const [],
      required Map<String, Set<String>?> dependencies,
      required List<String> keyColumns}) {
    dependencies = Map.unmodifiable({
      for (final entry in dependencies.entries)
        entry.key:
            entry.value == null ? null : Set<String>.unmodifiable(entry.value!),
    });
    keyColumns = List.unmodifiable(keyColumns);
    final args = List<Object?>.unmodifiable(
        parameters.map((v) => v is Uint8List ? Uint8List.fromList(v) : v));
    return registry.watch(
        sql: sql,
        parameters: args,
        dependencies: dependencies,
        keyColumns: keyColumns,
        evaluate: () async {
          final sources = {for (final s in await changes.sources()) s.table: s};
          for (final dep in dependencies.entries) {
            if (dep.key == '*') continue;
            final source = sources[dep.key];
            if (source == null) {
              throw StateError(
                  'Reactive dependency must remain tracked: ${dep.key}');
            }
            final columns = dep.value;
            if (columns != null && !columns.every(source.columns.contains)) {
              throw StateError(
                  'Changes must capture every declared dependency column');
            }
            if (columns == null) {
              final info = await changes.exclusive((db) => db.query(
                  'PRAGMA table_info("${dep.key.replaceAll('"', '""')}")'));
              if (!info.rows.every((r) => source.columns.contains(r[1]))) {
                throw StateError(
                    'All-column dependency needs complete source capture');
              }
            }
          }
          return changes.exclusive((db) => db.query(sql, args));
        },
        decode: (row) => Map.unmodifiable(row));
  }

  Future<void> flush() => registry.flush();
  Future<void> close() => registry.close();
}
