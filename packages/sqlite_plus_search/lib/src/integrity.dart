part of 'search.dart';

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

extension on SqlitePlusSearch {
  Future<String> _integrityDigest(_Metadata meta) async {
    final output = _DigestSink();
    final sink = crypto.sha256.startChunkedConversion(output);
    void add(Object? value) {
      sink.add(utf8.encode(jsonEncode(value, toEncodable: (value) {
        if (value is BigInt) return {'integer': value.toString()};
        throw StateError('Invalid index value');
      })));
      sink.add([10]);
    }

    Object? cell(Object? value) =>
        value is Uint8List ? {'blob': base64Encode(value)} : value;
    add([
      meta.id,
      meta.key,
      meta.schema,
      meta.analyzer,
      meta.modelId,
      meta.dimensions,
      meta.columns,
      meta.autoUpdate
    ]);
    final prefix = '_sps_${meta.id}_';
    final catalog =
        await database.query('SELECT name,type,sql FROM sqlite_schema');
    final owned = catalog.rows
        .where((row) => (row[0] as String).startsWith(prefix))
        .toList()
      ..sort((a, b) => (a[0] as String).compareTo(b[0] as String));
    for (final entry in owned) {
      add(entry);
      if (entry[1] != 'table' ||
          entry[0] == '${prefix}pending' ||
          (entry[2] as String).toUpperCase().contains('CREATE VIRTUAL TABLE')) {
        continue;
      }
      final rows =
          await database.query('SELECT * FROM ${_quote(entry[0] as String)}');
      add(rows.columns);
      final canonical = rows.rows
          .map(
              (row) => jsonEncode(row.map(cell).toList(), toEncodable: (value) {
                    if (value is BigInt) return {'integer': value.toString()};
                    throw StateError('Invalid index value');
                  }))
          .toList()
        ..sort();
      for (final row in canonical) {
        add(row);
      }
    }
    sink.close();
    return output.value.toString();
  }

  Future<void> _recordIntegrity(_Metadata meta) async {
    final digest = await _integrityDigest(meta);
    await database.execute('DELETE FROM _sps_integrity WHERE collection_id=?',
        [BigInt.parse(meta.id)]);
    await database.execute('INSERT INTO _sps_integrity VALUES (?,1,?)',
        [BigInt.parse(meta.id), digest]);
  }
}
