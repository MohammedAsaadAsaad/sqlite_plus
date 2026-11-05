part of 'search.dart';

extension on SqlitePlusSearch {
  Future<void> _installTriggers(
      String table, _Metadata meta, List<String> columns) async {
    final base = '_sps_${meta.id}';
    String key(String scope) => 'CAST($scope.${_quote(meta.key)} AS TEXT)';
    await database.execute(
        'CREATE TRIGGER ${base}_insert AFTER INSERT ON ${_quote(table)} BEGIN '
        'INSERT INTO ${base}_pending(source_key) VALUES (${key('NEW')}); END');
    await database.execute(
        'CREATE TRIGGER ${base}_delete AFTER DELETE ON ${_quote(table)} BEGIN '
        'INSERT INTO ${base}_pending(source_key) VALUES (${key('OLD')}); END');
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
      final mapping =
          await database.query('SELECT id,source_key FROM ${base}_keys');
      final ids = {for (final row in mapping.rows) row[1] as String: row[0]};
      // REPLACE can delete a different UNIQUE-conflicting row without firing
      // DELETE triggers when recursive_triggers is off. Reconcile missing keys
      // whenever an insert/update event is replayed; only affected entries are
      // rewritten, rather than rebuilding the collection.
      final liveKeys = await database
          .query('SELECT ${_quote(meta.key)} FROM ${_quote(table)}');
      final present = liveKeys.rows.map((row) => row[0].toString()).toSet();
      final changed = {
        ...pending.rows.map((row) => row[1] as String),
        ...ids.keys.where((key) => !present.contains(key)),
      };
      final columns =
          await database.query('PRAGMA table_info(${_quote(table)})');
      final declared =
          (columns.rows.firstWhere((row) => row[1] == meta.key)[2] as String)
              .toUpperCase();
      final integerKey = declared.contains('INT');
      final typedKey =
          integerKey || ['CHAR', 'CLOB', 'TEXT'].any(declared.contains);
      for (final sourceKey in changed) {
        final originalId = ids[sourceKey];
        if (!present.contains(sourceKey)) {
          if (originalId != null) {
            await database
                .execute('DELETE FROM ${base}_fts WHERE rowid=?', [originalId]);
            if (meta.modelId != null) {
              await database.execute(
                  'DELETE FROM ${base}_vec WHERE rowid=?', [originalId]);
            }
            await database
                .execute('DELETE FROM ${base}_keys WHERE id=?', [originalId]);
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
        var id = originalId;
        if (id == null) {
          final inserted = await database.execute(
              'INSERT INTO ${base}_keys(source_key,body) VALUES (?,?)',
              [sourceKey, analyzer.normalize(text)]);
          id = inserted.lastInsertRowid;
        } else {
          await database.execute('UPDATE ${base}_keys SET body=? WHERE id=?',
              [analyzer.normalize(text), id]);
        }
        await database.execute(
            'INSERT OR REPLACE INTO ${base}_fts(rowid,body) VALUES (?,?)',
            [id, analyzer.normalize(text)]);
        if (meta.modelId != null) {
          final vector = await validatedEmbedding(embeddingProvider!, text);
          await database.execute(
              'INSERT OR REPLACE INTO ${base}_vec(rowid,embedding) VALUES (?,?)',
              [id, encodeVec(vector)]);
        }
      }
      // Only acknowledge the events read before this replay, after every derived
      // change succeeds. Failure leaves both the old index and durable log intact.
      for (final event in pending.rows) {
        await database
            .execute('DELETE FROM ${base}_pending WHERE id=?', [event[0]]);
      }
      await database.execute('DELETE FROM _sps_feedback WHERE collection_id=?',
          [BigInt.parse(meta.id)]);
      await _recordIntegrity(meta);
    });
  }
}
