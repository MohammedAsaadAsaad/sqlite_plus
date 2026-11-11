import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

Object? copyDiagnosticValue(Object? value) =>
    value is Uint8List ? Uint8List.fromList(value) : value;
Object encodeDiagnosticValue(Object? value) {
  if (value == null) return ['null'];
  // Match the engine's parameter normalization on each platform.
  if (value is int) value = BigInt.from(value);
  if (value is BigInt &&
      value >= -(BigInt.one << 63) &&
      value < BigInt.one << 63) {
    return ['integer', value.toString()];
  }
  if (value is double && value.isFinite) return ['real', value];
  if (value is String) return ['text', value];
  if (value is Uint8List) return ['blob', base64Encode(value)];
  throw const FormatException('Expected finite SQL value');
}

Object? decodeDiagnosticValue(Object? raw) {
  if (raw is! List || raw.isEmpty) throw const FormatException('SQL value');
  if (raw.length == 1 && raw[0] == 'null') return null;
  if (raw.length != 2) throw const FormatException('SQL width');
  switch (raw[0]) {
    case 'integer':
      final v = BigInt.parse(raw[1] as String);
      if (v.toString() != raw[1]) throw const FormatException('Integer');
      encodeDiagnosticValue(v);
      return v;
    case 'real':
      final v = (raw[1] as num).toDouble();
      if (!v.isFinite) throw const FormatException('Real');
      return v;
    case 'text':
      return raw[1] as String;
    case 'blob':
      return base64Decode(raw[1] as String);
    default:
      throw const FormatException('SQL type');
  }
}

String diagnosticHash(List<int> bytes) => sha256.convert(bytes).toString();
String queryProof(QueryResult result, {bool unordered = false}) {
  final rows = result.rows
      .map((r) => jsonEncode(r.map(encodeDiagnosticValue).toList()))
      .toList();
  if (unordered) rows.sort();
  return diagnosticHash(utf8.encode(jsonEncode([result.columns, rows])));
}

/// Compare schema, visible rows, accessible hidden rowids and persistent pragmas;
/// B-tree packing and page counters are not application state.
Future<String> logicalImageProof(Uint8List image,
    {required int maxRows}) async {
  final db = await MutableSqliteDatabase.fromImage(image);
  try {
    final schema = await db.query(
        'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name');
    final proof = <Object?>[queryProof(schema)];
    var rows = 0;
    for (final entry in schema.rows) {
      if (entry[0] != 'table') continue;
      final sql = entry[3] as String?;
      if (sql == null || sql.toUpperCase().contains('VIRTUAL TABLE')) {
        throw StateError('Logical replay validation requires ordinary tables');
      }
      final table = DatabaseCatalog.parseTable(sql, 1);
      if (table.columns.any((c) => c.generatedExpression != null)) {
        throw StateError('Generated-column replay validation is unsupported');
      }
      final names = table.columns.map((c) => c.name.toLowerCase()).toSet();
      final rowid = table.withoutRowid
          ? null
          : ['rowid', '_rowid_', 'oid']
              .where((n) => !names.contains(n))
              .firstOrNull;
      final projection = rowid == null ? '*' : '"$rowid",*';
      final name = entry[1] as String;
      final result = await db
          .query('SELECT $projection FROM "${name.replaceAll('"', '""')}"');
      rows += result.rows.length;
      if (rows > maxRows) {
        throw StateError('Replay logical-state row budget exceeded');
      }
      proof.add([name, queryProof(result, unordered: true)]);
    }
    for (final name in ['application_id', 'user_version', 'encoding']) {
      proof.add(queryProof(await db.query('PRAGMA $name')));
    }
    return diagnosticHash(utf8.encode(jsonEncode(proof)));
  } finally {
    await db.close();
  }
}
