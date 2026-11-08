part of '../sqlite_plus_inspector.dart';

String _cut(String value, int maximum) =>
    value.length <= maximum ? value : '${value.substring(0, maximum - 1)}…';

String _asciiUpper(String value) => String.fromCharCodes(
    value.codeUnits.map((c) => c >= 97 && c <= 122 ? c - 32 : c));

final class _Template {
  const _Template(this.sql, this.fingerprint, this.analyzed);
  final String sql, fingerprint;
  final bool analyzed;
}

_Template _template(String sql, InspectorOptions options) {
  if (sql.length > options.maxAnalysisChars) {
    return _Template(_cut('[SQL too large to analyze]', options.maxSqlChars),
        'oversized', false);
  }
  try {
    final tokens = SqlTokenizer.tokenize(sql);
    final normalized = tokens
        .where((t) => t.kind != SqlTokenKind.end)
        .map((t) => switch (t.kind) {
              SqlTokenKind.string ||
              SqlTokenKind.number ||
              SqlTokenKind.blob ||
              SqlTokenKind.parameter =>
                '?',
              SqlTokenKind.identifier => t.quoted
                  ? '"${t.text.replaceAll('"', '""')}"'
                  : _asciiUpper(t.text),
              _ => t.text,
            })
        .join(' ');
    return _Template(_cut(normalized, options.maxSqlChars),
        sha256.convert(utf8.encode(normalized)).toString(), true);
  } catch (_) {
    // Never retain a malformed SQL fragment: it may contain an unfinished secret.
    return _Template(
        _cut('[SQL unavailable]', options.maxSqlChars), 'unavailable', false);
  }
}

String _parameter(Object? value, InspectorOptions options) {
  if (value == null) return 'NULL';
  if (value is Uint8List) return '<blob:${value.length} bytes>';
  if (value is String) {
    return options.captureParameters
        ? jsonEncode(_cut(value, options.maxValueChars))
        : '<text:${value.length} chars>';
  }
  if (value is int || value is BigInt || value is double || value is bool) {
    return options.captureParameters
        ? _cut(value.toString(), options.maxValueChars)
        : '<${value is bool ? 'boolean' : value is int || value is BigInt ? 'integer' : 'real'}>';
  }
  return '<unsupported>';
}

final class _Group {
  _Group(
      this.template, this.connectionId, this.connectionLabel, this.operation);
  final _Template template;
  final int connectionId;
  final String connectionLabel;
  final InspectorOperation operation;
  int count = 0, failures = 0, slowCount = 0, total = 0, maximum = 0;
  void add(InspectorRecord record) {
    count++;
    if (!record.success) failures++;
    if (record.slow) slowCount++;
    total += record.duration.inMicroseconds;
    if (record.duration.inMicroseconds > maximum) {
      maximum = record.duration.inMicroseconds;
    }
  }

  InspectorQueryGroup snapshot() => InspectorQueryGroup._(
      template.sql,
      template.fingerprint,
      connectionId,
      connectionLabel,
      operation,
      template.analyzed,
      count,
      failures,
      slowCount,
      Duration(microseconds: total),
      Duration(microseconds: maximum));
}

final class _ScopeFrame {
  _ScopeFrame(this.id, this.name, this.parent, this.epoch);
  final int id, epoch;
  final String name;
  final _ScopeFrame? parent;
  final clock = Stopwatch()..start();
  final groups = <String, _Group>{};
  int queryCount = 0,
      executeCount = 0,
      failures = 0,
      total = 0,
      droppedGroups = 0;
  bool closed = false;
}

/// In-memory collector. Only explicitly wrapped calls are observed.
final class SqlInspector {
  SqlInspector({InspectorOptions? options, bool enabled = true})
      : options = options ?? InspectorOptions(),
        _enabled = enabled;
  final InspectorOptions options;
  final _records = ListQueue<InspectorRecord>(),
      _scopes = ListQueue<InspectorScope>();
  final _groups = <String, _Group>{};
  final _scopeKey = Object();
  bool _enabled, _closed = false;
  int _epoch = 0,
      _nextSequence = 0,
      _nextConnection = 0,
      _nextScope = 0,
      _activeScopes = 0,
      _inFlight = 0,
      _skippedMeasurements = 0;
  int _queries = 0, _executes = 0, _failures = 0, _slow = 0, _total = 0;
  int _droppedRecords = 0,
      _droppedGroups = 0,
      _droppedScopes = 0,
      _diagnosticErrors = 0;
  bool get enabled => _enabled && !_closed;
  set enabled(bool value) {
    if (_closed && value) throw StateError('Inspector is closed');
    _enabled = value;
  }

  bool get isClosed => _closed;
  InspectorConnection connection(String label) => InspectorConnection._(
      this, ++_nextConnection, _cut(label, options.maxLabelChars));

  /// Disabled returns the original future without timing/tokenizing the call.
  Future<T> measure<T>(String sql, List<Object?> parameters,
      InspectorOperation operation, Future<T> Function() action,
      {InspectorConnection? connection,
      int? Function(T)? rows,
      int? Function(T)? affectedRows}) {
    if (!enabled) return action();
    if (connection != null && !identical(connection._owner, this)) {
      throw ArgumentError('Foreign inspector connection');
    }
    if (_inFlight >= options.maxInFlight) {
      _skippedMeasurements++;
      return action();
    }
    _inFlight++;
    return _measure(
            sql, parameters, operation, action, connection, rows, affectedRows)
        .whenComplete(() => _inFlight--);
  }

  Future<T> _measure<T>(
      String sql,
      List<Object?> parameters,
      InspectorOperation operation,
      Future<T> Function() action,
      InspectorConnection? connection,
      int? Function(T)? rows,
      int? Function(T)? affectedRows) async {
    final epoch = _epoch;
    final parameterCount = parameters.length;
    final template = _template(sql, options);
    final previews = <String>[];
    try {
      previews.addAll(parameters
          .take(options.maxParameters)
          .map((v) => _parameter(v, options)));
    } catch (_) {
      _diagnosticErrors++;
    }
    final frame = Zone.current[_scopeKey] as _ScopeFrame?;
    final clock = Stopwatch()..start();
    T result;
    try {
      result = await action();
    } catch (error) {
      clock.stop();
      _complete(epoch, template, operation, parameterCount, previews,
          connection, frame, clock.elapsed, false,
          errorType: _cut(error.runtimeType.toString(), 64));
      rethrow;
    }
    clock.stop();
    int? count, changes;
    try {
      count = rows?.call(result);
      changes = affectedRows?.call(result);
    } catch (_) {
      _diagnosticErrors++;
    }
    _complete(epoch, template, operation, parameterCount, previews, connection,
        frame, clock.elapsed, true,
        rowCount: count, affectedRows: changes);
    return result;
  }

  void _complete(
      int epoch,
      _Template template,
      InspectorOperation operation,
      int parameterCount,
      List<String> parameters,
      InspectorConnection? connection,
      _ScopeFrame? frame,
      Duration duration,
      bool success,
      {String? errorType,
      int? rowCount,
      int? affectedRows}) {
    if (!enabled || epoch != _epoch) return;
    try {
      final slow = duration >= options.slowThreshold;
      if (operation == InspectorOperation.query) {
        _queries++;
      } else {
        _executes++;
      }
      if (!success) _failures++;
      if (slow) _slow++;
      _total += duration.inMicroseconds;
      while (frame != null && (frame.closed || frame.epoch != epoch)) {
        frame = frame.parent;
      }
      final record = InspectorRecord._(
          sequence: ++_nextSequence,
          operation: operation,
          sql: template.sql,
          fingerprint: template.fingerprint,
          analyzed: template.analyzed,
          connectionId: connection?.id ?? 0,
          connectionLabel: connection?.label ?? '',
          duration: duration,
          success: success,
          slow: slow,
          parameterCount: parameterCount,
          parameters: parameters,
          rowCount: rowCount,
          affectedRows: affectedRows,
          errorType: errorType,
          scopeId: frame?.id);
      if (options.maxRecords == 0) {
        _droppedRecords++;
      } else {
        if (_records.length == options.maxRecords) {
          _records.removeFirst();
          _droppedRecords++;
        }
        _records.add(record);
      }
      final key =
          '${record.connectionId}:${operation.name}:${template.fingerprint}';
      _droppedGroups += _addGroup(_groups, key, template, record);
      while (frame != null) {
        if (!frame.closed && frame.epoch == epoch) {
          if (operation == InspectorOperation.query) {
            frame.queryCount++;
          } else {
            frame.executeCount++;
          }
          if (!success) frame.failures++;
          frame.total += duration.inMicroseconds;
          frame.droppedGroups += _addGroup(frame.groups, key, template, record);
        }
        frame = frame.parent;
      }
    } catch (_) {
      _diagnosticErrors++;
    }
  }

  int _addGroup(Map<String, _Group> groups, String key, _Template template,
      InspectorRecord record) {
    if (options.maxGroups == 0) return 1;
    var group = groups.remove(key);
    var dropped = 0;
    if (group == null) {
      if (groups.length == options.maxGroups) {
        groups.remove(groups.keys.first);
        dropped++;
      }
      group = _Group(template, record.connectionId, record.connectionLabel,
          record.operation);
    }
    group.add(record);
    groups[key] = group;
    return dropped;
  }

  /// Await all child work you want included. Nested scopes are inclusive.
  Future<T> scope<T>(String name, Future<T> Function() action) {
    if (!enabled) return action();
    var parent = Zone.current[_scopeKey] as _ScopeFrame?;
    while (parent != null && (parent.closed || parent.epoch != _epoch)) {
      parent = parent.parent;
    }
    var depth = 0;
    for (var f = parent; f != null; f = f.parent) {
      depth++;
    }
    if (depth >= options.maxScopeDepth ||
        _activeScopes >= options.maxActiveScopes) {
      _droppedScopes++;
      return action();
    }
    final frame = _ScopeFrame(
        ++_nextScope, _cut(name, options.maxLabelChars), parent, _epoch);
    _activeScopes++;
    return runZoned(() async {
      var success = false;
      try {
        final value = await action();
        success = true;
        return value;
      } finally {
        frame.clock.stop();
        frame.closed = true;
        _activeScopes--;
        if (enabled && frame.epoch == _epoch) {
          if (options.maxScopes == 0) {
            _droppedScopes++;
          } else {
            if (_scopes.length == options.maxScopes) {
              _scopes.removeFirst();
              _droppedScopes++;
            }
            _scopes.add(InspectorScope._(
                id: frame.id,
                name: frame.name,
                parentId: frame.parent?.id,
                duration: frame.clock.elapsed,
                statementDuration: Duration(microseconds: frame.total),
                queryCount: frame.queryCount,
                executeCount: frame.executeCount,
                failures: frame.failures,
                success: success,
                droppedGroups: frame.droppedGroups,
                groups: frame.groups.values.map((g) => g.snapshot()),
                repeatedReadThreshold: options.repeatedReadThreshold));
          }
        }
        frame.groups.clear();
      }
    }, zoneValues: {_scopeKey: frame});
  }

  InspectorSnapshot snapshot() => InspectorSnapshot._(
      queryCount: _queries,
      executeCount: _executes,
      failures: _failures,
      slowCount: _slow,
      totalDuration: Duration(microseconds: _total),
      droppedRecords: _droppedRecords,
      droppedGroups: _droppedGroups,
      droppedScopes: _droppedScopes,
      diagnosticErrors: _diagnosticErrors,
      skippedMeasurements: _skippedMeasurements,
      records: _records,
      groups: _groups.values.map((g) => g.snapshot()),
      scopes: _scopes);
  void clear() {
    _epoch++;
    _records.clear();
    _groups.clear();
    _scopes.clear();
    _queries = 0;
    _executes = 0;
    _failures = 0;
    _slow = 0;
    _total = 0;
    _droppedRecords = 0;
    _droppedGroups = 0;
    _droppedScopes = 0;
    _diagnosticErrors = 0;
    _skippedMeasurements = 0;
  }

  /// Stops observation; existing query futures/connection lifetimes are untouched.
  void close() {
    _closed = true;
    _enabled = false;
  }
}
