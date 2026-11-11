/// Explicit sensitive diagnostic capture. Ordinary Inspector records stay redacted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'sqlite_plus_inspector.dart';
import 'src/diagnostic_values.dart';

final class ReplayLimits {
  const ReplayLimits(
      {this.maxImageBytes = 8 * 1024 * 1024,
      this.maxArtifactBytes = 32 * 1024 * 1024,
      this.maxStatements = 1000,
      this.maxSqlChars = 65536,
      this.maxParameters = 1000,
      this.maxStateRows = 10000});
  final int maxImageBytes,
      maxArtifactBytes,
      maxStatements,
      maxSqlChars,
      maxParameters,
      maxStateRows;
  void _validate() {
    if (maxImageBytes < 512 ||
        maxArtifactBytes < 1024 ||
        maxStatements < 1 ||
        maxStatements > 10000 ||
        maxSqlChars < 1 ||
        maxSqlChars > 1048576 ||
        maxStateRows < 1 ||
        maxParameters < 0 ||
        maxParameters > 10000) {
      throw ArgumentError('Invalid replay limits');
    }
  }
}

void _replaySql(String sql, ReplayLimits limits) {
  if (sql.length > limits.maxSqlChars) throw const FormatException('SQL limit');
  final tokens = SqlTokenizer.tokenize(sql)
      .where((t) => t.kind != SqlTokenKind.end)
      .toList();
  if (tokens.isEmpty ||
      ![
        'SELECT',
        'WITH',
        'INSERT',
        'UPDATE',
        'DELETE',
        'BEGIN',
        'COMMIT',
        'END',
        'ROLLBACK',
        'SAVEPOINT',
        'RELEASE'
      ].contains(tokens.first.keyword)) {
    throw const FormatException(
        'Only DML, SELECT and transaction SQL is replayable');
  }
  if (tokens.last.kind == SqlTokenKind.symbol && tokens.last.text == ';') {
    tokens.removeLast();
  }
  if (tokens.any((t) =>
      (t.kind == SqlTokenKind.symbol && t.text == ';') ||
      (t.kind == SqlTokenKind.identifier &&
          ['ATTACH', 'DETACH', 'PRAGMA', 'VACUUM', 'LOAD_EXTENSION']
              .contains(t.keyword)))) {
    throw const FormatException('Host/schema SQL is not replayable');
  }
}

final class ReplayReport {
  const ReplayReport(
      this.executedStatements, this.firstMismatch, this.finalStateMatches,
      {this.physicalImageMatches = false});
  final int executedStatements;
  final int? firstMismatch;
  final bool finalStateMatches, physicalImageMatches;
  bool get matches => firstMismatch == null && finalStateMatches;
}

/// Immutable artifact interface; contains sensitive plaintext SQL, bindings and
/// initial database image. Checksums detect corruption, not hostile authorship.
final class SqlReplayArtifact {
  SqlReplayArtifact._(
      this._image, this._steps, this._finalImage, this._limits, this._settings);
  final Uint8List _image;
  final List<Map<String, Object?>> _steps;
  final Uint8List _finalImage;
  final ReplayLimits _limits;
  final Map<String, bool> _settings;
  int get statementCount => _steps.length;

  Uint8List toBytes() {
    final payload = jsonEncode({
      'format': 1,
      'settings': _settings,
      'base': base64Encode(_image),
      'steps': _steps,
      'final': base64Encode(_finalImage)
    });
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(
        {'payload': payload, 'sha256': diagnosticHash(utf8.encode(payload))})));
    if (bytes.length > _limits.maxArtifactBytes) {
      throw StateError('Artifact budget exceeded');
    }
    return bytes;
  }

  static SqlReplayArtifact fromBytes(Uint8List bytes,
      {ReplayLimits limits = const ReplayLimits()}) {
    limits._validate();
    try {
      if (bytes.length > limits.maxArtifactBytes) {
        throw const FormatException('Artifact limit');
      }
      final raw = jsonDecode(utf8.decode(bytes)) as Map;
      final payload = raw['payload'] as String;
      if (diagnosticHash(utf8.encode(payload)) != raw['sha256']) {
        throw const FormatException('Checksum');
      }
      final data = jsonDecode(payload) as Map;
      if (data['format'] != 1 ||
          (data['base'] as String).length > limits.maxImageBytes * 4 ~/ 3 + 4) {
        throw const FormatException('Version/image limit');
      }
      final image = base64Decode(data['base'] as String);
      if (image.length > limits.maxImageBytes) {
        throw const FormatException('Image limit');
      }
      final steps = <Map<String, Object?>>[];
      final input = data['steps'] as List;
      if (input.length > limits.maxStatements) {
        throw const FormatException('Statement limit');
      }
      for (final entry in input) {
        final step = (entry as Map).cast<String, Object?>();
        _replaySql(step['sql'] as String, limits);
        if (!['query', 'execute'].contains(step['operation'])) {
          throw const FormatException('Operation');
        }
        final args = step['parameters'] as List;
        if (args.length > limits.maxParameters) {
          throw const FormatException('Parameters');
        }
        for (final value in args) {
          decodeDiagnosticValue(value);
        }
        final outcome = step['outcome'] as Map;
        if (outcome['kind'] != 'ok' && outcome['kind'] != 'error') {
          throw const FormatException('Outcome');
        }
        if (outcome['kind'] == 'error' && outcome['type'] is! String) {
          throw const FormatException('Error');
        }
        steps.add(step);
      }
      final finalEncoded = data['final'] as String;
      if (finalEncoded.length > limits.maxImageBytes * 4 ~/ 3 + 4) {
        throw const FormatException('Final image limit');
      }
      final finalImage = base64Decode(finalEncoded);
      if (finalImage.length > limits.maxImageBytes) {
        throw const FormatException('Final image limit');
      }
      final settings = (data['settings'] as Map).cast<String, bool>();
      if (settings.length != 3 ||
          !['foreign_keys', 'recursive_triggers', 'doubleQuotedStrings']
              .every(settings.containsKey)) {
        throw const FormatException('Settings');
      }
      return SqlReplayArtifact._(
          image, steps, finalImage, limits, Map.unmodifiable(settings));
    } catch (error) {
      throw FormatException('Invalid replay artifact: ${error.runtimeType}');
    }
  }

  /// Always executes on a new in-memory engine. No caller-supplied target exists.
  /// Compare logical state/outcomes; nondeterministic SQL may intentionally diverge.
  Future<ReplayReport> replay() async {
    final db = await MutableSqliteDatabase.fromImage(_image);
    var executed = 0;
    try {
      for (final name in ['foreign_keys', 'recursive_triggers']) {
        await db.execute('PRAGMA $name=${_settings[name]! ? 'ON' : 'OFF'}');
      }
      db.doubleQuotedStrings = _settings['doubleQuotedStrings']!;
      for (var i = 0; i < _steps.length; i++) {
        final step = _steps[i];
        final args =
            (step['parameters'] as List).map(decodeDiagnosticValue).toList();
        final outcome = await _outcome(() => step['operation'] == 'query'
            ? db.query(step['sql'] as String, args)
            : db.execute(step['sql'] as String, args));
        executed++;
        if (jsonEncode(outcome) != jsonEncode(step['outcome'])) {
          return ReplayReport(executed, i, false);
        }
      }
      if (db.inTransaction) return ReplayReport(executed, _steps.length, false);
      final actualImage = db.exportImage();
      final actual =
          await logicalImageProof(actualImage, maxRows: _limits.maxStateRows);
      final expected =
          await logicalImageProof(_finalImage, maxRows: _limits.maxStateRows);
      return ReplayReport(executed, null, actual == expected,
          physicalImageMatches:
              diagnosticHash(actualImage) == diagnosticHash(_finalImage));
    } finally {
      await db.close();
    }
  }
}

Map<String, Object?> _success(Object result) => result is QueryResult
    ? {'kind': 'ok', 'proof': queryProof(result)}
    : result is MutationResult
        ? {
            'kind': 'ok',
            'affected': result.changes,
            'proof':
                result.returning == null ? null : queryProof(result.returning!)
          }
        : throw StateError('Unexpected diagnostic result');
Future<Map<String, Object?>> _outcome(Future<Object> Function() action) async {
  try {
    return _success(await action());
  } catch (error) {
    return {'kind': 'error', 'type': error.runtimeType.toString()};
  }
}

/// Only calls through this recorder are captured. Exclusively loan the source;
/// finish all raw transactions before construction and all recorded ones before
/// finish. There is no schema/registry capture or engine-wide tracing.
final class SqlReplayRecorder {
  SqlReplayRecorder._(this.database, this.limits, this._settings, this._image,
      SqlInspector? inspector) {
    _observed = inspector?.database(database, label: 'diagnostic-recording');
    _bytes = (_image.length * 4 ~/ 3) + 1024;
  }
  static Future<SqlReplayRecorder> start(MutableSqliteDatabase database,
      {SqlInspector? inspector,
      ReplayLimits limits = const ReplayLimits()}) async {
    limits._validate();
    if (database.inTransaction) throw StateError('Caller transaction open');
    final settings = <String, bool>{
      'doubleQuotedStrings': database.doubleQuotedStrings
    };
    for (final name in ['foreign_keys', 'recursive_triggers']) {
      settings[name] =
          (await database.query('PRAGMA $name')).rows.single.single ==
              BigInt.one;
    }
    final image = database.exportImage();
    if (image.length > limits.maxImageBytes) {
      throw StateError('Replay image budget exceeded');
    }
    return SqlReplayRecorder._(
        database, limits, Map.unmodifiable(settings), image, inspector);
  }

  final MutableSqliteDatabase database;
  final ReplayLimits limits;
  final Uint8List _image;
  final Map<String, bool> _settings;
  InspectedConnection? _observed;
  final _steps = <Map<String, Object?>>[];
  late int _bytes;
  bool _busy = false, _finished = false, _complete = true;
  bool get isComplete => _complete;
  bool get isFinished => _finished;

  Future<T> _run<T extends Object>(String sql, List<Object?> parameters,
      String operation, Future<T> Function(List<Object?>) action) async {
    if (_busy || _finished) throw StateError('Recorder busy or finished');
    _busy = true;
    Map<String, Object?>? step;
    var args = parameters;
    try {
      if (_complete) {
        try {
          _replaySql(sql, limits);
          if (_steps.length >= limits.maxStatements ||
              parameters.length > limits.maxParameters) {
            throw const FormatException('Capture limit');
          }
          final wire = parameters.map(encodeDiagnosticValue).toList();
          args = wire.map(decodeDiagnosticValue).toList();
          step = {'sql': sql, 'parameters': wire, 'operation': operation};
          _bytes += utf8.encode(jsonEncode(step)).length + 512;
          if (_bytes > limits.maxArtifactBytes) {
            throw const FormatException('Capture bytes');
          }
        } catch (_) {
          _complete = false;
          step = null;
        }
      }
      try {
        final result = await action(args);
        if (step != null) {
          try {
            step['outcome'] = _success(result);
            _steps.add(step);
          } catch (_) {
            _complete = false;
          }
        }
        return result;
      } catch (error, stack) {
        if (step != null) {
          step['outcome'] = {
            'kind': 'error',
            'type': error.runtimeType.toString()
          };
          _steps.add(step);
        }
        Error.throwWithStackTrace(error, stack);
      }
    } finally {
      _busy = false;
    }
  }

  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      _run(sql, parameters, 'query',
          (args) => _observed?.query(sql, args) ?? database.query(sql, args));
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      _run(
          sql,
          parameters,
          'execute',
          (args) =>
              _observed?.execute(sql, args) ?? database.execute(sql, args));

  SqlReplayArtifact finish() {
    if (_busy || _finished || !_complete || database.inTransaction) {
      throw StateError(
          'Finish requires a complete, idle session outside transactions');
    }
    final finalImage = database.exportImage();
    if (finalImage.length > limits.maxImageBytes) {
      throw StateError('Final image budget exceeded');
    }
    final artifact = SqlReplayArtifact._(Uint8List.fromList(_image),
        List.of(_steps), Uint8List.fromList(finalImage), limits, _settings);
    try {
      artifact.toBytes();
    } catch (_) {
      _complete = false;
      rethrow;
    }
    _finished = true;
    return artifact;
  }
}
