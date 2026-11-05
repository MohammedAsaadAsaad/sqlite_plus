part of 'search.dart';

final class _IntegrityPart {
  _IntegrityPart(this.count, this.sum);
  int count;
  final Uint8List sum;
}

final class _OwnedTable {
  _OwnedTable(this.name, this.virtual);
  final String name;
  final bool virtual;
}

/// Version 2 is an order-independent sum of per-row hashes. A one-row sync
/// updates the touched rows and rehashes only the small shadow tables.
/// [verifyIndex] still recomputes every row.
const _integrityVersion = 2;

extension on SqlitePlusSearch {
  Object? _integrityCell(Object? value) =>
      value is Uint8List ? {'blob': base64Encode(value)} : value;

  Object? _integrityEncodable(Object? value) {
    if (value is BigInt) return {'integer': value.toString()};
    throw StateError('Invalid index value');
  }

  Uint8List _rowHash(List<Object?> row) {
    final canonical = jsonEncode(row.map(_integrityCell).toList(),
        toEncodable: _integrityEncodable);
    return Uint8List.fromList(
        crypto.sha256.convert(utf8.encode(canonical)).bytes);
  }

  void _addHash(Uint8List sum, List<int> hash, int sign) {
    var carry = 0;
    for (var i = 0; i < sum.length; i++) {
      final next = sum[i] + sign * hash[i] + carry;
      sum[i] = next & 0xff;
      carry = next >> 8;
    }
  }

  _IntegrityPart _partFromRows(List<List<Object?>> rows) {
    final sum = Uint8List(32);
    for (final row in rows) {
      _addHash(sum, _rowHash(row), 1);
    }
    return _IntegrityPart(rows.length, sum);
  }

  bool _pointTable(String prefix, String name) =>
      name == '${prefix}keys' ||
      name == '${prefix}fts_docsize' ||
      name == '${prefix}vec_vec';

  Future<(List<Object?>, List<_OwnedTable>)> _integrityCatalog(
      _Metadata meta) async {
    final prefix = '_sps_${meta.id}_';
    final catalog =
        await database.query('SELECT name,type,sql FROM sqlite_schema');
    final owned = catalog.rows
        .where((row) => (row[0] as String).startsWith(prefix))
        .toList()
      ..sort((a, b) => (a[0] as String).compareTo(b[0] as String));
    final tables = <_OwnedTable>[];
    for (final entry in owned) {
      if (entry[1] != 'table' ||
          entry[0] == '${prefix}pending' ||
          entry[0] == '${prefix}census' ||
          entry[2] is! String) {
        continue;
      }
      final virtual =
          (entry[2] as String).toUpperCase().contains('CREATE VIRTUAL TABLE');
      tables.add(_OwnedTable(entry[0] as String, virtual));
    }
    return (
      [
        meta.id,
        meta.key,
        meta.schema,
        meta.analyzer,
        meta.modelId,
        meta.dimensions,
        meta.columns,
        meta.autoUpdate,
        [
          for (final entry in owned) entry,
        ]
      ],
      tables
    );
  }

  Future<Map<String, _IntegrityPart>> _integrityParts(
      List<_OwnedTable> tables) async {
    final parts = <String, _IntegrityPart>{};
    for (final table in tables) {
      if (table.virtual) continue;
      final rows = await database.query('SELECT * FROM ${_quote(table.name)}');
      parts[table.name] = _partFromRows(rows.rows);
    }
    return parts;
  }

  String _digestOf(List<Object?> header, Map<String, _IntegrityPart> parts) {
    final names = parts.keys.toList()..sort();
    final payload = [
      header,
      for (final name in names)
        [name, parts[name]!.count, base64Encode(parts[name]!.sum)]
    ];
    return crypto.sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  Future<String> _integrityDigest(_Metadata meta) async {
    final catalog = await _integrityCatalog(meta);
    return _digestOf(catalog.$1, await _integrityParts(catalog.$2));
  }

  String _encodeParts(Map<String, _IntegrityPart> parts) => jsonEncode({
        for (final entry in parts.entries)
          entry.key: {
            'n': entry.value.count,
            's': base64Encode(entry.value.sum)
          }
      });

  Map<String, _IntegrityPart>? _decodeParts(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) return null;
    final parts = <String, _IntegrityPart>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (entry.key is! String || value is! Map || value['s'] is! String) {
        return null;
      }
      final count = value['n'];
      if (count is! int && count is! num) return null;
      final sum = base64Decode(value['s'] as String);
      if (sum.length != 32) return null;
      parts[entry.key as String] =
          _IntegrityPart(count is int ? count : (count as num).toInt(), sum);
    }
    return parts;
  }

  Future<void> _storeIntegrity(
      _Metadata meta, String digest, Map<String, _IntegrityPart> parts) async {
    final id = BigInt.parse(meta.id);
    await database
        .execute('DELETE FROM _sps_integrity WHERE collection_id=?', [id]);
    await database.execute('INSERT INTO _sps_integrity VALUES (?,?,?)',
        [id, BigInt.from(_integrityVersion), digest]);
    await database.execute(
        'DELETE FROM _sps_integrity_state WHERE collection_id=?', [id]);
    await database.execute('INSERT INTO _sps_integrity_state VALUES (?,?)',
        [id, _encodeParts(parts)]);
  }

  Future<void> _recordIntegrity(_Metadata meta) async {
    final catalog = await _integrityCatalog(meta);
    final parts = await _integrityParts(catalog.$2);
    await _storeIntegrity(meta, _digestOf(catalog.$1, parts), parts);
  }

  /// Adjusts stored per-table sums after a replay.
  ///
  /// [deltas] name a per-document table and the old and new `SELECT *` image
  /// of one row. Posting and census tables are rehashed because they are not
  /// one row per document. A missing baseline falls back to a full fingerprint.
  Future<void> _refreshIntegrity(
      _Metadata meta,
      List<({String table, List<Object?>? before, List<Object?>? after})>
          deltas) async {
    final id = BigInt.parse(meta.id);
    final stored = await database.query(
        'SELECT parts FROM _sps_integrity_state WHERE collection_id=?', [id]);
    if (stored.rows.length != 1 || stored.rows.single.single is! String) {
      await _recordIntegrity(meta);
      return;
    }
    final parts = _decodeParts(stored.rows.single.single as String);
    if (parts == null) {
      await _recordIntegrity(meta);
      return;
    }
    final prefix = '_sps_${meta.id}_';
    for (final delta in deltas) {
      final part = parts[delta.table];
      if (part == null || !_pointTable(prefix, delta.table)) {
        await _recordIntegrity(meta);
        return;
      }
      if (delta.before != null) {
        _addHash(part.sum, _rowHash(delta.before!), -1);
        if (delta.after == null) part.count -= 1;
      }
      if (delta.after != null) {
        _addHash(part.sum, _rowHash(delta.after!), 1);
        if (delta.before == null) part.count += 1;
      }
      if (part.count < 0) {
        await _recordIntegrity(meta);
        return;
      }
    }
    final catalog = await _integrityCatalog(meta);
    final live = {for (final table in catalog.$2) table.name};
    for (final table in catalog.$2) {
      if (table.virtual || _pointTable(prefix, table.name)) continue;
      final rows = await database.query('SELECT * FROM ${_quote(table.name)}');
      parts[table.name] = _partFromRows(rows.rows);
    }
    for (final name in live) {
      final virtual =
          catalog.$2.any((table) => table.name == name && table.virtual);
      if (!virtual && !parts.containsKey(name)) {
        await _recordIntegrity(meta);
        return;
      }
    }
    parts.removeWhere((name, _) => !live.contains(name));
    await _storeIntegrity(meta, _digestOf(catalog.$1, parts), parts);
  }
}
