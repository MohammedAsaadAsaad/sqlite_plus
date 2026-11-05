import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

import 'analyzer.dart';
import 'embedding.dart';
import 'ranking.dart';

part 'learning.dart';
part 'integrity.dart';
part 'synchronization.dart';

/// Retrieval strategy. Semantic and hybrid require a local embedding provider.
enum SearchMode { keyword, semantic, hybrid }

/// A SQL predicate evaluated against the original source table.
///
/// SQL is trusted application code, never user input. Bind all user values in
/// [parameters]. Do not include WHERE, ORDER BY or LIMIT.
final class SearchFilter {
  SearchFilter(this.sql, [List<Object?> parameters = const []])
      : parameters = List.unmodifiable(parameters) {
    if (sql.trim().isEmpty || sql.contains(';') || sql.contains('\u0000')) {
      throw ArgumentError('Expected one SQL predicate');
    }
  }
  final String sql;
  final List<Object?> parameters;
}

final class SearchHit {
  const SearchHit(
      {required this.documentId, required this.score, this.explanation});
  final Map<String, double>? explanation;
  final String documentId;

  /// Larger scores rank first. Keyword scores negate the engine's BM25 value.
  final double score;
}

final class SearchResults {
  SearchResults(
      {required this.searchId,
      required List<SearchHit> hits,
      required this.total})
      : hits = List.unmodifiable(hits);
  final String searchId;
  final List<SearchHit> hits;
  final int total;
}

/// Search indexes on an application-owned database.
///
/// The caller retains ownership and must not interleave external operations
/// during search operations. Calls through this facade are serialized per DB.
/// Existing application transactions are rejected rather than committed.
final class SqlitePlusSearch {
  SqlitePlusSearch._(
      this.database, this.analyzer, this.embeddingProvider, this.learning);
  final MutableSqliteDatabase database;
  final SearchAnalyzer analyzer;
  final LocalEmbeddingProvider? embeddingProvider;
  final AdaptiveLearningConfig learning;
  SearchFeedback get feedback => SearchFeedback._(this);
  static final _queues = Expando<Future<void>>();

  static Future<SqlitePlusSearch> open({
    required MutableSqliteDatabase database,
    bool offlineOnly = true,
    SearchAnalyzer analyzer = const SearchTextAnalyzer(),
    LocalEmbeddingProvider? embeddingProvider,
    AdaptiveLearningConfig learning = const AdaptiveLearningConfig(),
  }) async {
    if (!offlineOnly) {
      throw ArgumentError('Only offline operation is supported');
    }
    if (embeddingProvider != null &&
        (embeddingProvider.modelId.trim().isEmpty ||
            embeddingProvider.dimensions < 1 ||
            embeddingProvider.dimensions > 4096)) {
      throw ArgumentError('Invalid embedding model identity or dimensions');
    }
    if (!learning.learningRate.isFinite ||
        learning.learningRate <= 0 ||
        learning.learningRate > 0.5) {
      throw ArgumentError('Learning rate must be in (0,0.5]');
    }
    final search =
        SqlitePlusSearch._(database, analyzer, embeddingProvider, learning);
    await search._run(() async {
      SqlitePlusVec.register(database);
      await database.execute('CREATE TABLE IF NOT EXISTS _sps_collections ('
          'id INTEGER PRIMARY KEY, source TEXT NOT NULL UNIQUE, '
          'key_column TEXT NOT NULL, text_columns TEXT NOT NULL, '
          'schema_sql TEXT NOT NULL, analyzer TEXT NOT NULL, version INTEGER NOT NULL, model_id TEXT, dimensions INTEGER, auto_update INTEGER NOT NULL)');
      await database.execute(
          'CREATE TABLE IF NOT EXISTS _sps_models (collection_id INTEGER PRIMARY KEY, version INTEGER NOT NULL, weights TEXT NOT NULL)');
      await database.execute(
          'CREATE TABLE IF NOT EXISTS _sps_feedback (id INTEGER PRIMARY KEY,search_id TEXT NOT NULL,document_id TEXT NOT NULL,collection_id INTEGER NOT NULL,f_keyword REAL NOT NULL,f_vector REAL NOT NULL,used INTEGER NOT NULL)');
      await database.execute(
          'CREATE TABLE IF NOT EXISTS _sps_state (id INTEGER PRIMARY KEY, next_search INTEGER NOT NULL)');
      await database.execute('INSERT OR IGNORE INTO _sps_state VALUES (1,1)');
      await database.execute(
          'CREATE TABLE IF NOT EXISTS _sps_integrity (collection_id INTEGER PRIMARY KEY, version INTEGER NOT NULL, digest TEXT NOT NULL)');
      await database.execute(
          'CREATE TABLE IF NOT EXISTS _sps_integrity_state (collection_id INTEGER PRIMARY KEY, parts TEXT NOT NULL)');
    });
    return search;
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final previous = _queues[database] ?? Future<void>.value();
    final next = previous.then((_) async {
      if (database.inTransaction) {
        throw StateError('Search requires exclusive use outside a transaction');
      }
      return action();
    });
    _queues[database] =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<T> _transaction<T>(Future<T> Function() action) async {
    await database.execute('BEGIN');
    try {
      final result = await action();
      await database.execute('COMMIT');
      return result;
    } catch (error, stack) {
      if (database.inTransaction) {
        try {
          await database.execute('ROLLBACK');
        } catch (_) {
          // A failed durable commit poisons the engine connection. Preserve the
          // original failure; recovery requires reopening the database.
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Creates or explicitly rebuilds a derived index without copying source rows.
  /// Text in FTS is derived index data; source application records stay in place.
  /// With autoUpdate, transactional triggers record edits for replay before search.
  Future<void> indexTable(
          {required String table,
          required String primaryKey,
          required List<String> textColumns,
          bool autoUpdate = false}) =>
      _run(() async {
        SqlitePlusVec.register(database);
        _identifier(table);
        _identifier(primaryKey);
        if (table.toLowerCase().startsWith('_sps_') ||
            textColumns.isEmpty ||
            textColumns.toSet().length != textColumns.length) {
          throw ArgumentError('Invalid source table or text columns');
        }
        for (final column in textColumns) {
          _identifier(column);
        }
        await _transaction(() async {
          final schema = await _schema(table);
          final info =
              await database.query('PRAGMA table_info(${_quote(table)})');
          final names = info.rows.map((row) => row[1]).toSet();
          final keys = info.rows.where((row) => row[5] != BigInt.zero).toList();
          if (keys.length != 1 ||
              keys.single[1] != primaryKey ||
              !names.containsAll(textColumns)) {
            throw ArgumentError(
                'Expected a single declared primary key and existing text columns');
          }
          final existing = await database.query(
              'SELECT id FROM _sps_collections NOT INDEXED WHERE source = ?',
              [table]);
          if (existing.rows.isEmpty) {
            await database.execute(
                'INSERT INTO _sps_collections '
                '(source,key_column,text_columns,schema_sql,analyzer,version,model_id,dimensions,auto_update) VALUES (?,?,?,?,?,$_indexFormat,?,?,?)',
                [
                  table,
                  primaryKey,
                  jsonEncode(textColumns),
                  schema,
                  analyzer.signature,
                  embeddingProvider?.modelId,
                  embeddingProvider?.dimensions,
                  autoUpdate ? 1 : 0
                ]);
          } else {
            await database.execute(
                'UPDATE _sps_collections SET key_column=?,text_columns=?,schema_sql=?,analyzer=?,version=$_indexFormat,model_id=?,dimensions=?,auto_update=? WHERE source=?',
                [
                  primaryKey,
                  jsonEncode(textColumns),
                  schema,
                  analyzer.signature,
                  embeddingProvider?.modelId,
                  embeddingProvider?.dimensions,
                  autoUpdate ? 1 : 0,
                  table
                ]);
          }
          final meta = await _metadata(table);
          final base = '_sps_${meta.id}';
          await database.execute(
              'DELETE FROM _sps_feedback WHERE collection_id=?',
              [BigInt.parse(meta.id)]);
          await database.execute(
              'DELETE FROM _sps_models WHERE collection_id=?',
              [BigInt.parse(meta.id)]);
          for (final event in ['insert', 'update', 'delete']) {
            await database.execute('DROP TRIGGER IF EXISTS ${base}_$event');
          }
          await database.execute('DROP TABLE IF EXISTS ${base}_pending');
          await database.execute('DROP TABLE IF EXISTS ${base}_census');
          await database.execute(
              'CREATE TABLE ${base}_pending (id INTEGER PRIMARY KEY,source_key TEXT NOT NULL)');
          await database.execute('DROP TABLE IF EXISTS ${base}_fts');
          await database.execute('DROP TABLE IF EXISTS ${base}_keys');
          await database.execute('DROP TABLE IF EXISTS ${base}_vectors');
          await database.execute('DROP TABLE IF EXISTS ${base}_vec');
          final provider = embeddingProvider;
          if (provider != null) {
            await database.execute(
                'CREATE VIRTUAL TABLE ${base}_vec USING vec0(embedding float[${provider.dimensions}] distance_metric=cosine)');
          }
          // Current engine external-content loading is positional: body must
          // be the first non-rowid column. The owned table also matches native
          // SQLite's column-name mapping.
          await database.execute(
              'CREATE TABLE ${base}_keys (id INTEGER PRIMARY KEY, body TEXT NOT NULL, source_key TEXT NOT NULL UNIQUE)');
          // Empty shadows are created before the load. A later CREATE would
          // serialize every key that had just been inserted.
          await database.execute(
              "CREATE VIRTUAL TABLE ${base}_fts USING fts5(body, content='${base}_keys', content_rowid='id')");
          if (autoUpdate) {
            await _installTriggers(table, meta, textColumns, 0);
          }
          // Read the source in pages so the whole table is not held beside the
          // derived rows. External-content FTS is built once after that load.
          final columns = [primaryKey, ...textColumns].map(_quote).join(',');
          var nextId = 1;
          Object? after;
          while (true) {
            final source = await database.browse(
                'SELECT rowid, $columns FROM ${_quote(table)}'
                '${after == null ? '' : ' WHERE rowid > ?'}'
                ' ORDER BY rowid LIMIT 1000',
                after == null ? const [] : [after]);
            if (source.rows.isEmpty) break;
            final keys = <Object?>[], vectors = <Object?>[];
            final values = <String>[];
            final vectorValues = <String>[];
            for (final row in source.rows) {
              final key = row[1];
              if (key is! String && key is! BigInt) {
                throw ArgumentError('Source keys must be text or integer');
              }
              final text = row.skip(2).map((value) {
                if (value != null && value is! String) {
                  throw ArgumentError('Indexed values must be text or null');
                }
                return value ?? '';
              }).join(' ');
              final id = nextId++;
              values.add('(?,?,?)');
              keys.addAll([id, key.toString(), analyzer.normalize(text)]);
              if (embeddingProvider != null) {
                final vector =
                    await validatedEmbedding(embeddingProvider!, text);
                vectorValues.add('(?,?)');
                vectors.addAll([id, encodeVec(vector)]);
              }
            }
            await database.execute(
                'INSERT INTO ${base}_keys(id,source_key,body) VALUES ${values.join(',')}',
                keys);
            if (vectorValues.isNotEmpty) {
              await database.execute(
                  'INSERT INTO ${base}_vec(rowid,embedding) VALUES ${vectorValues.join(',')}',
                  vectors);
            }
            after = source.rows.last[0];
            if (source.rows.length < 1000) break;
          }
          if (autoUpdate) {
            await database.execute(
                'UPDATE ${base}_census SET n=? WHERE id=1', [nextId - 1]);
          }
          await database.execute(
              "INSERT INTO ${base}_fts(${base}_fts) VALUES ('rebuild')");
          await _recordIntegrity(meta);
        });
      });

  Future<String> _schema(String table) async {
    final result = await database.query(
        'SELECT sql FROM sqlite_schema WHERE type = ? AND name = ?',
        ['table', table]);
    if (result.rows.length != 1 || result.rows.single[0] is! String) {
      throw StateError('Source table missing');
    }
    final sql = result.rows.single[0] as String;
    if (sql.toUpperCase().contains('VIRTUAL TABLE')) {
      throw ArgumentError('Source must be an ordinary table');
    }
    return sql;
  }

  Future<_Metadata> _metadata(String table) async {
    // Metadata scans deliberately avoid a stale empty unique-index lookup
    // observed in the engine inside a transaction (covered by regression test).
    final result = await database.query(
        'SELECT id,key_column,schema_sql,analyzer,version,model_id,dimensions,text_columns,auto_update FROM _sps_collections NOT INDEXED WHERE source = ?',
        [table]);
    if (result.rows.length != 1) throw StateError('Table is not indexed');
    final row = result.rows.single;
    if (row[4] != BigInt.from(_indexFormat)) {
      throw StateError('Unsupported search index version; explicitly rebuild');
    }
    try {
      return _Metadata(
          row[0].toString(),
          row[1] as String,
          row[2] as String,
          row[3] as String,
          row[5] as String?,
          (row[6] as BigInt?)?.toInt(),
          (jsonDecode(row[7] as String) as List).cast<String>(),
          row[8] == BigInt.one);
    } on FormatException {
      throw StateError('Corrupt collection metadata; explicitly rebuild');
    } on TypeError {
      throw StateError('Corrupt collection metadata; explicitly rebuild');
    }
  }

  /// Retrieves and ranks matches, replaying pending changes for autoUpdate indexes.
  Future<SearchResults> search(String query,
          {required String table,
          SearchMode mode = SearchMode.keyword,
          int limit = 10,
          int offset = 0,
          SearchFilter? filter,
          bool explain = false}) =>
      _run(() async {
        _identifier(table);
        if (limit < 1 || limit > 10000 || offset < 0) {
          throw ArgumentError('Invalid pagination');
        }
        final meta = await _metadata(table);
        if (meta.schema != await _schema(table) ||
            meta.analyzer != analyzer.signature) {
          throw StateError(
              'Schema or analyzer changed; explicitly rebuild the index');
        }
        await _drain(table, meta);
        final base = '_sps_${meta.id}';
        if (mode != SearchMode.keyword &&
            (embeddingProvider == null || meta.modelId == null)) {
          throw UnsupportedError(
              'Semantic search requires an indexed local embedding provider');
        }
        if (mode != SearchMode.keyword &&
            (meta.modelId != embeddingProvider!.modelId ||
                meta.dimensions != embeddingProvider!.dimensions)) {
          throw StateError(
              'Embedding model changed; explicitly rebuild the index');
        }
        final keyword = <SearchHit>[];
        final semantic = <SearchHit>[];
        // A correlated EXISTS against the source table scans once per key.
        // Load the source keys and the internal map separately instead.
        Set<String>? allowedKeys;
        Future<Set<String>> allowed() async {
          if (allowedKeys != null) return allowedKeys!;
          final rows = await database.query(
              'SELECT ${_quote(meta.key)} FROM ${_quote(table)}'
              '${filter == null ? '' : ' WHERE (${filter.sql})'}',
              filter?.parameters ?? const []);
          return allowedKeys =
              rows.rows.map((row) => row[0].toString()).toSet();
        }

        Map<BigInt, String>? keyMap;
        Future<Map<BigInt, String>> keys() async {
          if (keyMap != null) return keyMap!;
          final rows =
              await database.query('SELECT id, source_key FROM ${base}_keys');
          final ids = <BigInt, String>{};
          for (final row in rows.rows) {
            if (row[0] is! BigInt || row[1] is! String) {
              throw StateError('Search mapping is corrupt; rebuild index');
            }
            ids[row[0] as BigInt] = row[1] as String;
          }
          return keyMap = ids;
        }

        if (query.trim().isNotEmpty && mode != SearchMode.semantic) {
          // MATCH stays on the FTS table alone. Joining that virtual table
          // currently returns no rows, so eligible ids are resolved afterwards.
          final matched = await database.query(
              'SELECT rowid, bm25(${base}_fts) FROM ${base}_fts WHERE ${base}_fts MATCH ?',
              [analyzer.matchExpression(query)]);
          final scores = <BigInt, double>{};
          for (final row in matched.rows) {
            final id = row[0];
            final score = row[1];
            if (id is! BigInt || score is! num) {
              throw StateError('Search mapping is corrupt; rebuild index');
            }
            scores[id] = -score.toDouble();
          }
          final live = await allowed();
          final ids = scores.keys.toList();
          if (ids.length > 256) {
            final mapped = await keys();
            for (final id in ids) {
              final key = mapped[id];
              if (key == null) {
                throw StateError('Search mapping is corrupt; rebuild index');
              }
              if (live.contains(key)) {
                keyword.add(SearchHit(documentId: key, score: scores[id]!));
              }
            }
          } else {
            for (var start = 0; start < ids.length; start += 256) {
              final chunk =
                  ids.sublist(start, math.min(start + 256, ids.length));
              final placeholders = List.filled(chunk.length, '?').join(',');
              final mapped = await database.query(
                  'SELECT id, source_key FROM ${base}_keys WHERE id IN ($placeholders)',
                  chunk);
              final seen = <BigInt>{};
              for (final row in mapped.rows) {
                final id = row[0];
                final key = row[1];
                if (id is! BigInt || key is! String) {
                  throw StateError('Search mapping is corrupt; rebuild index');
                }
                seen.add(id);
                if (live.contains(key)) {
                  keyword.add(SearchHit(documentId: key, score: scores[id]!));
                }
              }
              if (seen.length != chunk.length) {
                throw StateError('Search mapping is corrupt; rebuild index');
              }
            }
          }
        }
        if (query.trim().isNotEmpty && mode != SearchMode.keyword) {
          final vector = await validatedEmbedding(embeddingProvider!, query);
          final mapped = await keys();
          final live = await allowed();
          final eligible = [
            for (final entry in mapped.entries)
              if (live.contains(entry.value)) entry.key
          ];
          if (filter != null) {
            final counts = await database.query(
                'SELECT (SELECT count(*) FROM ${base}_keys), (SELECT count(*) FROM ${base}_vec_vec)');
            if (counts.rows.single[0] != counts.rows.single[1]) {
              throw StateError('Vector index is incomplete; rebuild');
            }
          }
          final List<VecScore> scores;
          try {
            // No filter scans the shadow in rowid order. A filter passes only
            // the eligible ids, so ineligible embeddings are not decoded.
            scores = await rankVec0(
              database,
              table: '${base}_vec',
              query: vector,
              metric: 'cosine',
              rowIds: filter == null ? null : eligible,
              rejectZeroVectors: true,
            );
          } on SqlException catch (error) {
            if (error.message == 'vec0 row is missing') {
              throw StateError('Vector index is incomplete; rebuild');
            }
            throw StateError('Corrupt stored embedding; rebuild index');
          }
          if (filter == null && scores.length != mapped.length) {
            throw StateError(scores.length < mapped.length
                ? 'Vector index is incomplete; rebuild'
                : 'Vector mapping is corrupt; rebuild');
          }
          for (final score in scores) {
            final id = mapped[score.rowId];
            if (id == null) {
              throw StateError('Vector mapping is corrupt; rebuild');
            }
            if (!live.contains(id)) continue;
            semantic.add(SearchHit(
                documentId: id, score: (1 - score.distance).clamp(-1.0, 1.0)));
          }
        }
        keyword.sort(_compareHits);
        semantic.sort(_compareHits);
        final keywordRanks = {
          for (var i = 0; i < keyword.length; i++) keyword[i].documentId: i + 1
        };
        final semanticRanks = {
          for (var i = 0; i < semantic.length; i++)
            semantic[i].documentId: i + 1
        };
        final scores = mode == SearchMode.hybrid
            ? reciprocalRankFusion([
                keyword.map((h) => h.documentId).toList(),
                semantic.map((h) => h.documentId).toList()
              ])
            : {
                for (final hit
                    in mode == SearchMode.keyword ? keyword : semantic)
                  hit.documentId: hit.score
              };
        final weights = learning.enabled ? await _weights(meta.id) : [0.0, 0.0];
        final scale =
            scores.values.fold<double>(0, (a, b) => math.max(a, b.abs()));
        final hits = [
          for (final entry in scores.entries)
            SearchHit(
                documentId: entry.key,
                score: entry.value +
                    scale *
                        0.25 *
                        (weights[0] /
                                (keywordRanks[entry.key] ?? double.infinity) +
                            weights[1] /
                                (semanticRanks[entry.key] ?? double.infinity)),
                explanation: explain
                    ? Map<String, double>.unmodifiable({
                        if (keywordRanks.containsKey(entry.key))
                          'keywordRank': keywordRanks[entry.key]!.toDouble(),
                        if (semanticRanks.containsKey(entry.key))
                          'vectorRank': semanticRanks[entry.key]!.toDouble(),
                        'baseScore': entry.value,
                        'keywordWeight': weights[0],
                        'vectorWeight': weights[1],
                      })
                    : null)
        ]..sort(_compareHits);
        final searchId = await _transaction(() async {
          final state = await database
              .query('SELECT next_search FROM _sps_state WHERE id=1');
          final next = state.rows.single.single as BigInt;
          await database.execute(
              'UPDATE _sps_state SET next_search=? WHERE id=1',
              [next + BigInt.one]);
          final id = 'sps-$next';
          if (learning.enabled) {
            for (final hit in hits.skip(offset).take(limit)) {
              await database.execute(
                  'INSERT INTO _sps_feedback(search_id,document_id,collection_id,f_keyword,f_vector,used) VALUES (?,?,?,?,?,0)',
                  [
                    id,
                    hit.documentId,
                    BigInt.parse(meta.id),
                    1 / (keywordRanks[hit.documentId] ?? double.infinity),
                    1 / (semanticRanks[hit.documentId] ?? double.infinity)
                  ]);
            }
            final contexts = await database
                .query('SELECT id FROM _sps_feedback ORDER BY id DESC');
            for (final row in contexts.rows.skip(1000)) {
              await database
                  .execute('DELETE FROM _sps_feedback WHERE id=?', [row[0]]);
            }
          }
          return id;
        });
        return SearchResults(
            searchId: searchId,
            hits: hits.skip(offset).take(limit).toList(),
            total: hits.length);
      });

  /// Applies pending source changes without running a query. Source edits must
  /// be committed first; the same exclusive-use contract applies as for search.
  Future<void> synchronize({required String table}) => _run(() async {
        final meta = await _metadata(table);
        if (meta.schema != await _schema(table) ||
            meta.analyzer != analyzer.signature) {
          throw StateError(
              'Schema or analyzer changed; explicitly rebuild the index');
        }
        await _drain(table, meta);
      });

  /// Explicit, read-only corruption diagnostic over persisted derived data,
  /// metadata and trigger definitions. Pending source edits do not invalidate the
  /// baseline. Missing/changed data requires an explicit indexTable rebuild.
  /// This full scan is intentionally not performed on every search.
  Future<void> verifyIndex({required String table}) => _run(() async {
        final meta = await _metadata(table);
        if (meta.schema != await _schema(table)) {
          throw StateError('Source schema changed; explicitly rebuild');
        }
        final baseline = await database.query(
            'SELECT version,digest FROM _sps_integrity WHERE collection_id=?',
            [BigInt.parse(meta.id)]);
        if (baseline.rows.length != 1 ||
            baseline.rows.single[0] != BigInt.from(_integrityVersion)) {
          throw StateError(
              'Missing or unsupported integrity baseline; explicitly rebuild');
        }
        if (baseline.rows.single[1] != await _integrityDigest(meta)) {
          throw StateError(
              'Search index integrity mismatch; explicitly rebuild');
        }
      });

  Future<List<double>> _weights(String collection) async {
    final result = await database.query(
        'SELECT version,weights FROM _sps_models NOT INDEXED WHERE collection_id=?',
        [BigInt.parse(collection)]);
    if (result.rows.isEmpty) return [0, 0];
    final row = result.rows.single;
    if (row[0] != BigInt.one) {
      throw StateError('Unsupported ranking model version');
    }
    final decoded = jsonDecode(row[1] as String);
    if (decoded is! List ||
        decoded.length != 2 ||
        decoded
            .any((v) => v is! num || !v.toDouble().isFinite || v.abs() > 1)) {
      throw StateError('Corrupt ranking model');
    }
    return decoded.cast<num>().map((v) => v.toDouble()).toList();
  }

  Future<void> _saveWeights(String collection, List<num> weights) async {
    await database.execute('DELETE FROM _sps_models WHERE collection_id=?',
        [BigInt.parse(collection)]);
    await database.execute('INSERT INTO _sps_models VALUES (?,1,?)',
        [BigInt.parse(collection), jsonEncode(weights)]);
  }
}

final class _Metadata {
  _Metadata(this.id, this.key, this.schema, this.analyzer, this.modelId,
      this.dimensions, this.columns, this.autoUpdate);
  final String? modelId;
  final int? dimensions;
  final List<String> columns;
  final bool autoUpdate;
  final String id, key, schema, analyzer;
}

void _identifier(String value) {
  if (value.isEmpty || value.contains('\u0000')) {
    throw ArgumentError('Invalid identifier');
  }
}

String _quote(String value) => '"${value.replaceAll('"', '""')}"';

const _indexFormat = 3;

int _compareHits(SearchHit a, SearchHit b) {
  final score = b.score.compareTo(a.score);
  return score == 0 ? a.documentId.compareTo(b.documentId) : score;
}
