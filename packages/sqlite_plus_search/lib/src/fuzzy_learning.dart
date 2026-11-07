part of 'search.dart';

extension on SqlitePlusSearch {
  String _fuzzyKey(FuzzySearchConfig config) =>
      'v1:${analyzer.signature}:${config.maxEdits}:${config.minTokenLength}:${config.maxExpansions}:${config.learnAfter}';

  Future<bool> _hasFuzzyLearning() async => (await database.query(
          "SELECT name FROM sqlite_schema WHERE type='table' AND name='_sps_fuzzy_learning'"))
      .rows
      .isNotEmpty;

  Future<void> _clearFuzzyLearning(String collection) async {
    if (await _hasFuzzyLearning()) {
      await database.execute(
          'DELETE FROM _sps_fuzzy_learning WHERE collection_id=?',
          [BigInt.parse(collection)]);
    }
  }

  Future<Map<String, List<String>>> _readFuzzyLearning(
      String collection, String query, FuzzySearchConfig config) async {
    if (!await _hasFuzzyLearning()) return {};
    final result = <String, List<String>>{};
    for (final token in fuzzyTerms(query).toSet()) {
      final rows = await database.query(
          'SELECT alternatives,n FROM _sps_fuzzy_learning WHERE collection_id=? AND config=? AND token=?',
          [BigInt.parse(collection), _fuzzyKey(config), token]);
      if (rows.rows.isEmpty) continue;
      final row = rows.rows.single;
      if (row[1] is! BigInt || (row[1] as BigInt) < BigInt.one) {
        throw StateError('Corrupt fuzzy observations; rebuild index');
      }
      if ((row[1] as BigInt) < BigInt.from(config.learnAfter!)) continue;
      try {
        final values = (jsonDecode(row[0] as String) as List).cast<String>();
        if (values.isEmpty ||
            values.first != token ||
            values.length > config.maxExpansions + 1 ||
            values.any((value) => fuzzyTerms(value).toList().join() != value)) {
          throw StateError('Corrupt fuzzy alternatives; rebuild index');
        }
        result[token] = values;
      } on FormatException {
        throw StateError('Corrupt fuzzy alternatives; rebuild index');
      } on TypeError {
        throw StateError('Corrupt fuzzy alternatives; rebuild index');
      }
    }
    return result;
  }

  Future<void> _writeFuzzyLearning(String collection, FuzzySearchConfig config,
      Map<String, List<String>> alternatives) async {
    await database.execute('CREATE TABLE IF NOT EXISTS _sps_fuzzy_learning ('
        'id INTEGER PRIMARY KEY, collection_id INTEGER NOT NULL, config TEXT NOT NULL, '
        'token TEXT NOT NULL, alternatives TEXT NOT NULL, n INTEGER NOT NULL, '
        'UNIQUE(collection_id,config,token))');
    for (final entry in alternatives.entries) {
      final rows = await database.query(
          'SELECT id,n FROM _sps_fuzzy_learning WHERE collection_id=? AND config=? AND token=?',
          [BigInt.parse(collection), _fuzzyKey(config), entry.key]);
      if (rows.rows.isEmpty) {
        await database.execute(
            'INSERT INTO _sps_fuzzy_learning(collection_id,config,token,alternatives,n) VALUES (?,?,?,?,1)',
            [
              BigInt.parse(collection),
              _fuzzyKey(config),
              entry.key,
              jsonEncode(config.learnAfter == 1 ? entry.value : <String>[])
            ]);
      } else {
        final n = rows.rows.single[1] as BigInt;
        await database.execute(
            'UPDATE _sps_fuzzy_learning SET alternatives=?,n=? WHERE id=?', [
          jsonEncode(n + BigInt.one >= BigInt.from(config.learnAfter!)
              ? entry.value
              : <String>[]),
          n < BigInt.from(config.learnAfter!) ? n + BigInt.one : n,
          rows.rows.single[0]
        ]);
      }
    }
  }
}
