import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'workload.dart';

Future<void> main(List<String> args) =>
    workload(args, (db, sql, params, enabled, capacity) async {
      if (enabled) {
        final options = SqlDiagnosticOptions(maxCandidates: capacity);
        final report = db is SqliteDatabase
            ? await db.diagnoseQuery(sql, parameters: params, options: options)
            : db is InspectedConnection
                ? await db.profile(sql, parameters: params, options: options)
                : await (db as MutableSqliteDatabase)
                    .diagnoseQuery(sql, parameters: params, options: options);
        return ReadSample(report.result, report.toJson);
      }
      return ReadSample(await ordinaryRead(db, sql, params));
    });
