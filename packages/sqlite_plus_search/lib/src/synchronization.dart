part of 'search.dart';

extension on SqlitePlusSearch {
  Future<void> _installTriggers(String table, _Metadata meta,
      List<String> columns, int sourceRows) async {
    final base = '_sps_${meta.id}';
    String key(String scope) => 'CAST($scope.${_quote(meta.key)} AS TEXT)';
    await database.execute(
        'CREATE TABLE ${base}_census (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)');
    await database
        .execute('INSERT INTO ${base}_census VALUES (1,?)', [sourceRows]);
    await database.execute(
        'CREATE TRIGGER ${base}_insert AFTER INSERT ON ${_quote(table)} BEGIN '
        'INSERT INTO ${base}_pending(source_key) VALUES (${key('NEW')}); '
        'UPDATE ${base}_census SET n = n + 1 WHERE id = 1; END');
    await database.execute(
        'CREATE TRIGGER ${base}_delete AFTER DELETE ON ${_quote(table)} BEGIN '
        'INSERT INTO ${base}_pending(source_key) VALUES (${key('OLD')}); '
        'UPDATE ${base}_census SET n = n - 1 WHERE id = 1; END');
    await database.execute('CREATE TRIGGER ${base}_update AFTER UPDATE OF ${{
      meta.key,
      ...columns
    }.map(_quote).join(',')} ON ${_quote(table)} BEGIN '
        'INSERT INTO ${base}_pending(source_key) VALUES (${key('OLD')}); '
        'INSERT INTO ${base}_pending(source_key) VALUES (${key('NEW')}); END');
  }

  Future<void> _drain(String table, _Metadata meta) async {
    if (!meta.autoUpdate) return;
    final base = '_sps_${meta.id}';
    // Missing triggers must not silently imply a synchronized index.
    final triggers = await database
        .query("SELECT name FROM sqlite_schema WHERE type='trigger'");
    final names = triggers.rows.map((row) => row.single).toSet();
    if (!names
        .containsAll(['${base}_insert', '${base}_update', '${base}_delete'])) {
      throw StateError('Synchronization triggers missing; explicitly rebuild');
    }
    final pending =
        await database.query('SELECT id,source_key FROM ${base}_pending');
    if (pending.rows.isEmpty) return;
    if (meta.modelId != null &&
        (embeddingProvider == null ||
            meta.modelId != embeddingProvider!.modelId ||
            meta.dimensions != embeddingProvider!.dimensions)) {
      throw StateError(
          'Synchronizing vectors requires the original local model');
    }
    await _transaction(() async {
      await _clearFuzzyLearning(meta.id);
      final columns =
          await database.query('PRAGMA table_info(${_quote(table)})');
      final declared =
          (columns.rows.firstWhere((row) => row[1] == meta.key)[2] as String)
              .toUpperCase();
      final integerKey = declared.contains('INT');
      final typedKey =
          integerKey || ['CHAR', 'CLOB', 'TEXT'].any(declared.contains);
      final census =
          await database.query('SELECT n FROM ${base}_census WHERE id=1');
      final actual =
          await database.query('SELECT count(*) FROM ${_quote(table)}');
      final counted = census.rows.length == 1 &&
          census.rows.single.single == actual.rows.single.single;
      final deltas =
          <({String table, List<Object?>? before, List<Object?>? after})>[];
      if (counted) {
        final keys = <String>{
          for (final row in pending.rows)
            if (row[1] is String) row[1] as String
        };
        await _replayListed(
            table, meta, base, keys, integerKey, typedKey, deltas);
      } else {
        await _replayReconciled(
            table, meta, base, pending, integerKey, typedKey, deltas);
      }
      // Only acknowledge the events read before this replay, after every derived
      // change succeeds. Failure leaves both the old index and durable log intact.
      for (final event in pending.rows) {
        await database
            .execute('DELETE FROM ${base}_pending WHERE id=?', [event[0]]);
      }
      await database.execute('DELETE FROM _sps_feedback WHERE collection_id=?',
          [BigInt.parse(meta.id)]);
      await _refreshIntegrity(meta, deltas);
    });
  }

  Future<List<Object?>?> _derivedRow(String table, Object? id) async {
    if (id == null) return null;
    final rows =
        await database.query('SELECT * FROM $table WHERE rowid=?', [id]);
    if (rows.rows.isEmpty) return null;
    if (rows.rows.length != 1) {
      throw StateError('Search mapping is corrupt; rebuild index');
    }
    return rows.rows.single;
  }

  Future<void> _note(
      List<({String table, List<Object?>? before, List<Object?>? after})>
          deltas,
      String table,
      List<Object?>? before,
      List<Object?>? after) async {
    if (before == null && after == null) return;
    deltas.add((table: table, before: before, after: after));
  }

  Future<BigInt?> _mappedId(String base, String sourceKey) async {
    final indexed = await database
        .query('SELECT id FROM ${base}_keys WHERE source_key=?', [sourceKey]);
    if (indexed.rows.length == 1 && indexed.rows.single.single is BigInt) {
      return indexed.rows.single.single as BigInt;
    }
    if (indexed.rows.length > 1) {
      throw StateError('Search mapping is corrupt; rebuild index');
    }
    // An empty unique-index probe can be stale inside a transaction. The table
    // scan is the same answer the index should have returned.
    final scan = await database.query(
        'SELECT id FROM ${base}_keys NOT INDEXED WHERE source_key=?',
        [sourceKey]);
    if (scan.rows.isEmpty) return null;
    if (scan.rows.length != 1 || scan.rows.single.single is! BigInt) {
      throw StateError('Search mapping is corrupt; rebuild index');
    }
    return scan.rows.single.single as BigInt;
  }

  Future<void> _replayListed(
      String table,
      _Metadata meta,
      String base,
      Set<String> keys,
      bool integerKey,
      bool typedKey,
      List<({String table, List<Object?>? before, List<Object?>? after})>
          deltas) async {
    for (final sourceKey in keys) {
      final originalId = await _mappedId(base, sourceKey);
      final predicate =
          typedKey ? _quote(meta.key) : 'CAST(${_quote(meta.key)} AS TEXT)';
      final parameter =
          integerKey ? (BigInt.tryParse(sourceKey) ?? sourceKey) : sourceKey;
      final source = await database.query(
          'SELECT ${[
            meta.key,
            ...meta.columns
          ].map(_quote).join(',')} FROM ${_quote(table)} WHERE $predicate=?',
          [parameter]);
      if (source.rows.length > 1) {
        throw StateError('Source keys have ambiguous representations');
      }
      if (source.rows.isEmpty ||
          source.rows.single.first.toString() != sourceKey) {
        // A NOCASE primary key can answer a different spelling. That pending
        // key is gone; its new spelling is a separate pending event.
        if (originalId != null) {
          await _deleteDerived(meta, base, originalId, deltas);
        }
        continue;
      }
      await _applySourceRow(meta, base, sourceKey, originalId, source, deltas);
    }
  }

  Future<void> _replayReconciled(
      String table,
      _Metadata meta,
      String base,
      QueryResult pending,
      bool integerKey,
      bool typedKey,
      List<({String table, List<Object?>? before, List<Object?>? after})>
          deltas) async {
    final mapping =
        await database.query('SELECT id,source_key FROM ${base}_keys');
    final ids = {for (final row in mapping.rows) row[1] as String: row[0]};
    // REPLACE can delete a different UNIQUE-conflicting row without firing
    // DELETE triggers when recursive_triggers is off. Reconcile missing keys
    // whenever the trigger census no longer matches the source table.
    final liveKeys = await database
        .query('SELECT ${_quote(meta.key)} FROM ${_quote(table)}');
    final present = liveKeys.rows.map((row) => row[0].toString()).toSet();
    final changed = {
      ...pending.rows.map((row) => row[1] as String),
      ...ids.keys.where((key) => !present.contains(key)),
    };
    for (final sourceKey in changed) {
      final originalId = ids[sourceKey];
      if (!present.contains(sourceKey)) {
        if (originalId != null) {
          await _deleteDerived(meta, base, originalId, deltas);
        }
        continue;
      }
      final predicate =
          typedKey ? _quote(meta.key) : 'CAST(${_quote(meta.key)} AS TEXT)';
      final parameter =
          integerKey ? (BigInt.tryParse(sourceKey) ?? sourceKey) : sourceKey;
      final source = await database.query(
          'SELECT ${[
            meta.key,
            ...meta.columns
          ].map(_quote).join(',')} FROM ${_quote(table)} WHERE $predicate=?',
          [parameter]);
      await _applySourceRow(meta, base, sourceKey,
          originalId is BigInt ? originalId : null, source, deltas);
    }
  }

  Future<void> _applySourceRow(
      _Metadata meta,
      String base,
      String sourceKey,
      BigInt? originalId,
      QueryResult source,
      List<({String table, List<Object?>? before, List<Object?>? after})>
          deltas) async {
    if (source.rows.length != 1 ||
        source.rows.single.first.toString() != sourceKey) {
      throw StateError('Source keys have ambiguous representations');
    }
    final row = source.rows.single;
    if (row.first is! String && row.first is! BigInt) {
      throw ArgumentError('Source keys must be text or integer');
    }
    final text = row.skip(1).map((value) {
      if (value != null && value is! String) {
        throw ArgumentError('Indexed values must be text or null');
      }
      return value ?? '';
    }).join(' ');
    final normalized = analyzer.normalize(text);
    var id = originalId;
    final keysTable = '${base}_keys';
    final beforeKey = await _derivedRow(keysTable, id);
    if (id == null) {
      final inserted = await database.execute(
          'INSERT INTO ${base}_keys(source_key,body) VALUES (?,?)',
          [sourceKey, normalized]);
      id = inserted.lastInsertRowid;
    } else {
      await database.execute(
          'UPDATE ${base}_keys SET body=? WHERE id=?', [normalized, id]);
    }
    await _note(deltas, keysTable, beforeKey, await _derivedRow(keysTable, id));
    final sizeTable = '${base}_fts_docsize';
    final beforeSize = await _derivedRow(sizeTable, id);
    final vecTable = '${base}_vec_vec';
    final beforeVec =
        meta.modelId == null ? null : await _derivedRow(vecTable, id);
    await database.execute(
        'INSERT OR REPLACE INTO ${base}_fts(rowid,body) VALUES (?,?)',
        [id, normalized]);
    await _note(
        deltas, sizeTable, beforeSize, await _derivedRow(sizeTable, id));
    if (meta.modelId != null) {
      final vector = await validatedEmbedding(embeddingProvider!, text);
      await database.execute(
          'INSERT OR REPLACE INTO ${base}_vec(rowid,embedding) VALUES (?,?)',
          [id, encodeVec(vector)]);
      await _note(deltas, vecTable, beforeVec, await _derivedRow(vecTable, id));
    }
  }

  Future<void> _deleteDerived(
      _Metadata meta,
      String base,
      Object id,
      List<({String table, List<Object?>? before, List<Object?>? after})>
          deltas) async {
    final keysTable = '${base}_keys';
    final sizeTable = '${base}_fts_docsize';
    final vecTable = '${base}_vec_vec';
    final beforeKey = await _derivedRow(keysTable, id);
    final beforeSize = await _derivedRow(sizeTable, id);
    final beforeVec =
        meta.modelId == null ? null : await _derivedRow(vecTable, id);
    await database.execute('DELETE FROM ${base}_fts WHERE rowid=?', [id]);
    if (meta.modelId != null) {
      await database.execute('DELETE FROM ${base}_vec WHERE rowid=?', [id]);
    }
    await database.execute('DELETE FROM ${base}_keys WHERE id=?', [id]);
    await _note(deltas, keysTable, beforeKey, null);
    await _note(deltas, sizeTable, beforeSize, null);
    if (meta.modelId != null) await _note(deltas, vecTable, beforeVec, null);
  }
}
