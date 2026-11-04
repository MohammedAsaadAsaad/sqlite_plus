import 'package:sqlite_plus_geo/orm.dart';
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class Facility {
  Facility({this.rowid, required this.name, required this.location});

  BigInt? rowid;
  String name;
  GeoPoint location;
}

final _rowid = Column<Facility, BigInt?>(
  property: 'rowid',
  codec: Codecs.nullable(Codecs.bigInt),
  read: (facility) => facility.rowid,
  write: (facility, value) => facility.rowid = value,
  keyOrder: 0,
  generated: true,
);
final _name = Column<Facility, String>(
  property: 'name',
  codec: Codecs.text,
  read: (facility) => facility.name,
  write: (facility, value) => facility.name = value,
);
final _location = Column<Facility, GeoPoint>(
  property: 'location',
  codec: const GeoPointCodec(srid: 4326),
  read: (facility) => facility.location,
  write: (facility, value) => facility.location = value,
);
final _type = EntityType<Facility>(
  tableName: 'facilities',
  columns: [_rowid, _name, _location],
  create: (row) => Facility(
    rowid: row.read(_rowid),
    name: row.read(_name),
    location: row.read(_location),
  ),
);

void main() {
  test('the geometry codec rejects the wrong kind and round-trips EWKB', () {
    const codec = GeoPointCodec(srid: 4326);
    final point = GeoPoint(longitude: 34.3, latitude: 31.35, srid: 4326);
    expect(codec.decode(codec.encode(point)), point);
    expect(
      () => codec.encode(GeoPoint(longitude: 1, latitude: 2, srid: 3857)),
      throwsA(isA<GeoException>()),
    );
    expect(
      () => const GeoGeometryCodec(type: GeoGeometryType.point).decode(
        GeoLineString([GeoCoordinate(0, 0), GeoCoordinate(1, 1)]).toEwkb(),
      ),
      throwsA(isA<GeoException>()),
    );
  });

  test('a mapped facility survives save and reload', () async {
    final connection = await MutableDatabaseConnection.openMemory();
    final context = DbContext(connection, DbModel([_type]));
    try {
      await context.migrations.ensureCreated();
      final facilities = context.set(_type);
      facilities.add(
        Facility(
          name: 'Clinic',
          location: GeoPoint(longitude: 34.3, latitude: 31.35, srid: 4326),
        ),
      );
      expect(await context.saveChanges(), 1);
      final loaded = await facilities.query.toList();
      expect(loaded.single.name, 'Clinic');
      expect(loaded.single.location.position!.x, 34.3);
      expect(loaded.single.location.position!.y, 31.35);
    } finally {
      await context.close();
    }
  });
}
