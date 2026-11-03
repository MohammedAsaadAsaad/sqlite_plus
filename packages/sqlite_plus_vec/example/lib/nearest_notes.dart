import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

/// One brute-force nearest-neighbor query.
final class NearestNotes {
  const NearestNotes({
    required this.first,
    required this.secondPlanEmpty,
  });

  /// First coordinate of the nearest stored vector.
  final double first;

  /// Whether a second migration plan is empty.
  final bool secondPlanEmpty;
}

final class Point {
  Point({this.rowid, required this.embedding});

  BigInt? rowid;
  List<double> embedding;
}

final _rowid = Column<Point, BigInt?>(
  property: 'rowid',
  codec: Codecs.nullable(Codecs.bigInt),
  read: (point) => point.rowid,
  write: (point, value) => point.rowid = value,
  keyOrder: 0,
  generated: true,
);
final _embedding = Column<Point, List<double>>(
  property: 'embedding',
  codec: Codecs.vector(2),
  read: (point) => point.embedding,
  write: (point, value) => point.embedding = value,
  vectorDimensions: 2,
  vectorMetric: DbVectorMetrics.l2,
);
final _type = EntityType<Point>(
  tableName: 'points',
  columns: [_rowid, _embedding],
  virtualModule: DbModules.vec0,
  create: (row) =>
      Point(rowid: row.read(_rowid), embedding: row.read(_embedding)),
);

/// Registers vec0, saves two vectors, and reads the nearest neighbor.
Future<NearestNotes> runNearestNotes() async {
  final connection = await MutableDatabaseConnection.openMemory();
  SqlitePlusVec.register(connection.database);
  final context = DbContext(connection, DbModel([_type]));
  try {
    await context.migrations.ensureCreated();
    final points = context.set(_type);
    points.add(Point(embedding: const [1, 0]));
    points.add(Point(embedding: const [0, 1]));
    if (await context.saveChanges() != 2) {
      throw StateError('insert did not save two points');
    }
    final nearest = await points.query.nearest(const [0.9, 0.1], k: 1).single();
    return NearestNotes(
      first: nearest.embedding[0],
      secondPlanEmpty: (await context.migrations.plan()).isEmpty,
    );
  } finally {
    await context.close();
  }
}
