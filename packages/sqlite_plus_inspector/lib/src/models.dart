part of '../sqlite_plus_inspector.dart';

/// Row limits bound retained metadata, not SQL/engine temporary allocations.
final class InspectorOptions {
  InspectorOptions(
      {this.maxRecords = 500,
      this.maxGroups = 100,
      this.maxScopes = 50,
      this.maxScopeDepth = 16,
      this.maxActiveScopes = 100,
      this.maxInFlight = 100,
      this.maxSqlChars = 4096,
      this.maxAnalysisChars = 65536,
      this.maxParameters = 32,
      this.maxValueChars = 128,
      this.maxLabelChars = 128,
      this.captureParameters = false,
      this.slowThreshold = const Duration(milliseconds: 50),
      this.repeatedReadThreshold = 10}) {
    for (final value in [maxRecords, maxGroups, maxScopes]) {
      if (value < 0 || value > 10000) {
        throw ArgumentError('History limits must be 0..10000');
      }
    }
    if (maxScopeDepth < 1 ||
        maxScopeDepth > 64 ||
        maxActiveScopes < 1 ||
        maxActiveScopes > 10000 ||
        maxInFlight < 1 ||
        maxInFlight > 10000 ||
        maxSqlChars < 1 ||
        maxSqlChars > 65536 ||
        maxAnalysisChars < maxSqlChars ||
        maxAnalysisChars > 1048576 ||
        maxParameters < 0 ||
        maxParameters > 1000 ||
        maxValueChars < 1 ||
        maxValueChars > 4096 ||
        maxLabelChars < 1 ||
        maxLabelChars > 1024 ||
        slowThreshold.isNegative ||
        repeatedReadThreshold < 2) {
      throw ArgumentError('Invalid inspection limits');
    }
  }
  final int maxRecords,
      maxGroups,
      maxScopes,
      maxScopeDepth,
      maxActiveScopes,
      maxInFlight;
  final int maxSqlChars,
      maxAnalysisChars,
      maxParameters,
      maxValueChars,
      maxLabelChars;
  final bool captureParameters;
  final Duration slowThreshold;
  final int repeatedReadThreshold;
}

enum InspectorOperation { query, execute }

/// A collector-local connection identity; labels need not be globally unique.
final class InspectorConnection {
  InspectorConnection._(this._owner, this.id, this.label);
  final SqlInspector _owner;
  final int id;
  final String label;
}

final class InspectorRecord {
  InspectorRecord._(
      {required this.sequence,
      required this.operation,
      required this.sql,
      required this.fingerprint,
      required this.analyzed,
      required this.connectionId,
      required this.connectionLabel,
      required this.duration,
      required this.success,
      required this.slow,
      required this.parameterCount,
      required Iterable<String> parameters,
      this.rowCount,
      this.affectedRows,
      this.errorType,
      this.scopeId})
      : parameters = List.unmodifiable(parameters);
  final int sequence, connectionId, parameterCount;
  final InspectorOperation operation;
  final String sql, fingerprint, connectionLabel;
  final bool analyzed, success, slow;
  final Duration duration;
  final int? rowCount, affectedRows, scopeId;
  final String? errorType;
  final List<String> parameters;
  Map<String, Object?> toJson() => {
        'sequence': sequence,
        'operation': operation.name,
        'sql': sql,
        'fingerprint': fingerprint,
        'analyzed': analyzed,
        'connectionId': connectionId,
        'connection': connectionLabel,
        'durationUs': duration.inMicroseconds,
        'success': success,
        'slow': slow,
        'parameterCount': parameterCount,
        'parameters': parameters,
        'rowCount': rowCount,
        'affectedRows': affectedRows,
        'errorType': errorType,
        'scopeId': scopeId,
      };
}

final class InspectorQueryGroup {
  InspectorQueryGroup._(
      this.sql,
      this.fingerprint,
      this.connectionId,
      this.connectionLabel,
      this.operation,
      this.analyzed,
      this.count,
      this.failures,
      this.slowCount,
      this.totalDuration,
      this.maxDuration);
  final String sql, fingerprint, connectionLabel;
  final int connectionId, count, failures, slowCount;
  final InspectorOperation operation;
  final bool analyzed;
  final Duration totalDuration, maxDuration;
  Map<String, Object?> toJson() => {
        'sql': sql,
        'fingerprint': fingerprint,
        'connectionId': connectionId,
        'connection': connectionLabel,
        'operation': operation.name,
        'analyzed': analyzed,
        'count': count,
        'failures': failures,
        'slowCount': slowCount,
        'totalDurationUs': totalDuration.inMicroseconds,
        'maxDurationUs': maxDuration.inMicroseconds
      };
}

/// Inclusive nested operation counts. Repetition is a hint, not proof of N+1.
final class InspectorScope {
  InspectorScope._(
      {required this.id,
      required this.name,
      required this.duration,
      required this.statementDuration,
      required this.queryCount,
      required this.executeCount,
      required this.failures,
      required this.success,
      required this.droppedGroups,
      required Iterable<InspectorQueryGroup> groups,
      required this.repeatedReadThreshold,
      this.parentId})
      : groups = List.unmodifiable(groups);
  final int id,
      queryCount,
      executeCount,
      failures,
      droppedGroups,
      repeatedReadThreshold;
  final int? parentId;
  final String name;
  final bool success;
  final Duration duration, statementDuration;
  final List<InspectorQueryGroup> groups;
  List<InspectorQueryGroup> get repeatedReads =>
      List.unmodifiable(groups.where((g) =>
          g.analyzed &&
          g.operation == InspectorOperation.query &&
          g.count >= repeatedReadThreshold));
  Map<String, Object?> toJson() => {
        'id': id,
        'parentId': parentId,
        'name': name,
        'durationUs': duration.inMicroseconds,
        'statementDurationUs': statementDuration.inMicroseconds,
        'queryCount': queryCount,
        'executeCount': executeCount,
        'failures': failures,
        'success': success,
        'droppedGroups': droppedGroups,
        'groups': groups.map((g) => g.toJson()).toList(),
        'repeatedReads': repeatedReads.map((g) => g.toJson()).toList()
      };
}

final class InspectorSnapshot {
  InspectorSnapshot._(
      {required this.queryCount,
      required this.executeCount,
      required this.failures,
      required this.slowCount,
      required this.totalDuration,
      required this.droppedRecords,
      required this.droppedGroups,
      required this.droppedScopes,
      required this.diagnosticErrors,
      required this.skippedMeasurements,
      required Iterable<InspectorRecord> records,
      required Iterable<InspectorQueryGroup> groups,
      required Iterable<InspectorScope> scopes})
      : records = List.unmodifiable(records),
        groups = List.unmodifiable(groups),
        scopes = List.unmodifiable(scopes);
  final int queryCount,
      executeCount,
      failures,
      slowCount,
      droppedRecords,
      droppedGroups,
      droppedScopes,
      diagnosticErrors,
      skippedMeasurements;
  int get statementCount => queryCount + executeCount;
  final Duration totalDuration;
  final List<InspectorRecord> records;
  final List<InspectorQueryGroup> groups;
  final List<InspectorScope> scopes;
  Map<String, Object?> toJson() => {
        'queryCount': queryCount,
        'executeCount': executeCount,
        'failures': failures,
        'slowCount': slowCount,
        'totalDurationUs': totalDuration.inMicroseconds,
        'droppedRecords': droppedRecords,
        'droppedGroups': droppedGroups,
        'droppedScopes': droppedScopes,
        'diagnosticErrors': diagnosticErrors,
        'skippedMeasurements': skippedMeasurements,
        'records': records.map((r) => r.toJson()).toList(),
        'groups': groups.map((g) => g.toJson()).toList(),
        'scopes': scopes.map((s) => s.toJson()).toList()
      };
  String toJsonString() => jsonEncode(toJson());
}

/// Main-schema planning metadata from the engine; not execution bytecode.
final class InspectorPlan {
  InspectorPlan._(QueryPlan plan)
      : access = plan.access,
        indexName = plan.indexName,
        covering = plan.covering,
        rootPage = plan.rootPage,
        hasRowidBound = plan.rowid != null,
        coveredColumns = List.unmodifiable(plan.coveredColumns);
  final String access;
  final String? indexName;
  final int? rootPage;
  final bool covering, hasRowidBound;
  final List<String> coveredColumns;
  Map<String, Object?> toJson() => {
        'access': access,
        'indexName': indexName,
        'covering': covering,
        'rootPage': rootPage,
        'hasRowidBound': hasRowidBound,
        'coveredColumns': coveredColumns
      };
}
