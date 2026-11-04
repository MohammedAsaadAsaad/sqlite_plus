part of '../geo_engine.dart';

/// How a Dart spatial query used the R-tree. SQL `EXPLAIN QUERY PLAN` does
/// not show this plan: the engine has no spatial planner hook.
final class SpatialPlan {
  /// [candidates] is the R-tree hit count before the exact predicate.
  const SpatialPlan({
    required this.usedIndex,
    required this.indexName,
    required this.predicate,
    required this.candidates,
    required this.returned,
  });

  /// Whether an R-tree supplied the candidates.
  final bool usedIndex;

  /// Virtual table name, or an empty string when the query scanned the table.
  final String indexName;

  /// Exact predicate applied after the box filter.
  final String predicate;

  /// Rows read from the index or the table.
  final int candidates;

  /// Rows that passed the exact predicate.
  final int returned;

  /// One English sentence for logs and tests.
  String describe() => usedIndex
      ? 'spatial index $indexName produced $candidates candidates; exact $predicate kept $returned'
      : 'full scan produced $candidates candidates; exact $predicate kept $returned';
}

/// One indexed row.
final class GeoHit {
  /// [values] includes every selected column. Integers are [BigInt].
  const GeoHit({
    required this.rowid,
    required this.geometry,
    required this.values,
  });

  /// Table rowid.
  final BigInt rowid;

  /// Geometry from the requested column.
  final GeoGeometry geometry;

  /// Column values, excluding the internal rowid label when it was synthesized.
  final Map<String, Object?> values;
}

/// A nearest-neighbour hit. [distance] uses [metric].
final class GeoNeighbor {
  /// Equal distances are ordered by ascending rowid.
  const GeoNeighbor({
    required this.hit,
    required this.distance,
    required this.metric,
  });

  /// The stored row.
  final GeoHit hit;

  /// Distance in CRS units, or metres for a sphere or ellipsoid metric.
  final double distance;

  /// Formula that produced [distance].
  final GeodesicModel metric;
}

/// Predicate used by [GeoSession.intersects] and [GeoSession.join].
enum SpatialPredicate {
  /// Exact intersection.
  intersects,

  /// The left geometry is within the right geometry.
  within,

  /// The left geometry contains the right geometry.
  contains,

  /// Planar distance within a CRS-unit radius.
  dWithin,
}

extension GeoQueries on GeoSession {
  /// Index candidates, then exact [predicate]. A box hit is not a result.
  Future<({List<GeoHit> rows, SpatialPlan plan})> search(
    String table, {
    required String geometryColumn,
    required GeoGeometry geometry,
    SpatialPredicate predicate = SpatialPredicate.intersects,
    double? distance,
  }) async {
    final info = await _info(table, geometryColumn);
    _requireSameSrid(geometry,
        GeoPoint.empty(srid: info.srid == 0 ? geometry.srid : info.srid));
    final candidates =
        await _candidates(this, info, geometry.envelope, distance);
    final hits = <GeoHit>[];
    for (final hit in candidates) {
      final matches = switch (predicate) {
        SpatialPredicate.intersects => geoIntersects(hit.geometry, geometry),
        SpatialPredicate.within => geoWithin(hit.geometry, geometry),
        SpatialPredicate.contains => geoContains(hit.geometry, geometry),
        SpatialPredicate.dWithin =>
          geoDWithin(hit.geometry, geometry, distance ?? 0),
      };
      if (matches) hits.add(hit);
    }
    return (
      rows: hits,
      plan: SpatialPlan(
        usedIndex: info.spatialIndex != null && geometry.envelope != null,
        indexName: info.spatialIndex ?? '',
        predicate: predicate.name,
        candidates: candidates.length,
        returned: hits.length,
      ),
    );
  }

  /// Nearest rows. Geographic metres require SRID 4326 and a non-planar metric.
  /// Results are ordered by the exact distance, then by rowid.
  Future<({List<GeoNeighbor> rows, SpatialPlan plan})> nearest(
    String table, {
    required String geometryColumn,
    required GeoPoint point,
    int limit = 1,
    double? maxDistance,
    GeodesicModel metric = GeodesicModel.planar,
  }) async {
    if (limit < 1) throw const GeoException('nearest limit must be positive');
    if (point.isEmpty) throw const GeoException('nearest point is empty');
    if (metric != GeodesicModel.planar &&
        point.srid != 4326 &&
        point.srid != 0) {
      throw const GeoException('geographic nearest requires SRID 4326');
    }
    if (metric != GeodesicModel.planar && maxDistance != null) {
      // metres
    }
    final info = await _info(table, geometryColumn);
    final indexed = await _allIndexed(this, info);
    var span =
        metric == GeodesicModel.planar ? _initialSpan(point, indexed) : 0.05;
    List<GeoHit> pool = const [];
    while (true) {
      final envelope = _searchEnvelope(point, span, metric);
      pool = await _candidates(this, info, envelope, null);
      final ranked = _rank(pool, point, metric)
          .where((item) => maxDistance == null || item.distance <= maxDistance)
          .toList();
      final complete = pool.length == indexed ||
          ranked.length >= limit &&
              _ballInside(point, span, ranked[limit - 1].distance, metric);
      if (complete || span > 1000000) {
        ranked.sort((left, right) {
          final order = left.distance.compareTo(right.distance);
          if (order != 0) return order;
          return left.hit.rowid.compareTo(right.hit.rowid);
        });
        final kept = ranked.take(limit).toList();
        return (
          rows: kept,
          plan: SpatialPlan(
            usedIndex: info.spatialIndex != null,
            indexName: info.spatialIndex ?? '',
            predicate: 'nearest ${metric.name}',
            candidates: pool.length,
            returned: kept.length,
          ),
        );
      }
      span = span == 0 ? 1 : span * 2;
    }
  }

  /// Indexed nested-loop join. The right table's index filters candidates.
  Future<({List<({GeoHit left, GeoHit right})> rows, SpatialPlan plan})> join({
    required String leftTable,
    required String leftColumn,
    required String rightTable,
    required String rightColumn,
    SpatialPredicate predicate = SpatialPredicate.within,
    double? distance,
  }) async {
    final leftInfo = await _info(leftTable, leftColumn);
    final rightRows = await database.query(
      'SELECT rowid, ${leftInfo.column} FROM ${leftInfo.table}',
    );
    final pairs = <({GeoHit left, GeoHit right})>[];
    var candidates = 0;
    var usedIndex = false;
    for (final row in rightRows.rows) {
      if (row[1] == null) continue;
      final geometry = GeoGeometry.fromWkb(row[1]! as Uint8List);
      final leftHit = GeoHit(
        rowid: row[0]! as BigInt,
        geometry: geometry,
        values: {'rowid': row[0]},
      );
      final found = await search(
        rightTable,
        geometryColumn: rightColumn,
        geometry: geometry,
        predicate: predicate,
        distance: distance,
      );
      candidates += found.plan.candidates;
      usedIndex = usedIndex || found.plan.usedIndex;
      for (final hit in found.rows) {
        pairs.add((left: leftHit, right: hit));
      }
    }
    return (
      rows: pairs,
      plan: SpatialPlan(
        usedIndex: usedIndex,
        indexName: (await _info(rightTable, rightColumn)).spatialIndex ?? '',
        predicate: predicate.name,
        candidates: candidates,
        returned: pairs.length,
      ),
    );
  }
}

Future<List<GeoHit>> _candidates(
  GeoSession session,
  GeoColumnInfo info,
  GeoEnvelope? envelope,
  double? distance,
) async {
  if (info.spatialIndex != null && envelope != null) {
    final pad = distance ?? 0;
    // The engine rtree cursor reads every leaf and does not consume a box
    // constraint. One index scan, then the candidate rows, avoids repeating
    // that scan for every table row.
    final ids = await session.database.query(
      'SELECT id FROM ${info.spatialIndex} '
      'WHERE minX <= ? AND maxX >= ? AND minY <= ? AND maxY >= ?',
      [
        envelope.maxX + pad,
        envelope.minX - pad,
        envelope.maxY + pad,
        envelope.minY - pad,
      ],
    );
    final wanted = <BigInt>{
      for (final row in ids.rows)
        if (row[0] is BigInt) row[0]! as BigInt,
    };
    if (wanted.isEmpty) return const [];
    if (wanted.length > 32) {
      final rows = await session.database.query(
        'SELECT rowid, ${info.column} FROM ${info.table}',
      );
      return [
        for (final hit in _hits(rows, info.column))
          if (wanted.contains(hit.rowid)) hit,
      ];
    }
    final hits = <GeoHit>[];
    for (final rowid in wanted) {
      final rows = await session.database.query(
        'SELECT rowid, ${info.column} FROM ${info.table} WHERE rowid = ?',
        [rowid],
      );
      hits.addAll(_hits(rows, info.column));
    }
    return hits;
  }
  final rows = await session.database.query(
    'SELECT rowid, ${info.column} FROM ${info.table}',
  );
  return _hits(rows, info.column);
}

List<GeoHit> _hits(QueryResult result, String column) => [
      for (final row in result.rows)
        if (row[1] is Uint8List)
          GeoHit(
            rowid: row[0]! as BigInt,
            geometry: GeoGeometry.fromWkb(row[1]! as Uint8List),
            values: {column: row[1]},
          ),
    ];

Future<int> _allIndexed(GeoSession session, GeoColumnInfo info) async {
  final rows =
      await session.database.query('SELECT count(*) FROM ${info.table}');
  final value = rows.rows.single.single;
  if (value is BigInt) return value.toInt();
  return value as int;
}

double _initialSpan(GeoPoint point, int count) => count == 0 ? 1 : 1;

GeoEnvelope _searchEnvelope(GeoPoint point, double span, GeodesicModel metric) {
  final x = point.position!.x;
  final y = point.position!.y;
  return GeoEnvelope(
      minX: x - span, minY: y - span, maxX: x + span, maxY: y + span);
}

bool _ballInside(
    GeoPoint point, double span, double distance, GeodesicModel metric) {
  if (metric == GeodesicModel.planar) return distance <= span;
  final latitude = point.position!.y * math.pi / 180;
  final metresPerDegree = math.min(
    110574,
    111320 * math.cos(latitude).abs(),
  );
  return distance <= span * metresPerDegree;
}

List<GeoNeighbor> _rank(
    List<GeoHit> hits, GeoPoint point, GeodesicModel metric) {
  final ranked = <GeoNeighbor>[];
  for (final hit in hits) {
    final distance = switch (metric) {
      GeodesicModel.planar => _planarToPoint(hit.geometry, point),
      GeodesicModel.sphere || GeodesicModel.ellipsoid => _geographicToPoint(
          hit.geometry,
          point,
          metric,
        ),
    };
    ranked.add(GeoNeighbor(hit: hit, distance: distance, metric: metric));
  }
  return ranked;
}

double _planarToPoint(GeoGeometry geometry, GeoPoint point) {
  if (geometry.isEmpty) return double.infinity;
  try {
    return geoDistance(geometry, point);
  } on GeoException {
    return double.infinity;
  }
}

double _geographicToPoint(
    GeoGeometry geometry, GeoPoint point, GeodesicModel metric) {
  if (geometry is GeoPoint) {
    return GeoGeodesy.distance(geometry, point, model: metric);
  }
  var best = double.infinity;
  for (final coordinate in geometry.coordinates) {
    final distance = GeoGeodesy.distance(
      GeoPoint(longitude: coordinate.x, latitude: coordinate.y, srid: 4326),
      point,
      model: metric,
    );
    if (distance < best) best = distance;
  }
  return best;
}
