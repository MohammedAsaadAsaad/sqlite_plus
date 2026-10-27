import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

void main() {
  final codecError = throwsA(isA<OrmCodecException>());
  test('BigInt preserves both signed64 endpoints and rejects overflow', () {
    final minimum = -(BigInt.one << 63),
        maximum = (BigInt.one << 63) - BigInt.one;
    for (final value in [minimum, BigInt.zero, maximum]) {
      expect(Codecs.bigInt.decode(Codecs.bigInt.encode(value)), value);
    }
    for (final value in [minimum - BigInt.one, maximum + BigInt.one]) {
      expect(() => Codecs.bigInt.encode(value), codecError);
      expect(() => Codecs.bigInt.decode(value), codecError);
    }
    for (final value in [null, 1, 1.0, '1', true]) {
      expect(() => Codecs.bigInt.decode(value), codecError);
    }
  });

  test('int codec is bounded to portable53 before narrowing', () {
    const maximum = 9007199254740991;
    for (final value in [-maximum, 0, maximum]) {
      expect(Codecs.integer.encode(value), BigInt.from(value));
      expect(Codecs.integer.decode(BigInt.from(value)), value);
    }
    for (final value in [-maximum - 1, maximum + 1]) {
      expect(() => Codecs.integer.encode(value), codecError);
      expect(() => Codecs.integer.decode(BigInt.from(value)), codecError);
    }
    expect(() => Codecs.integer.decode(BigInt.one << 63), codecError);
    expect(() => Codecs.integer.decode(1.0), codecError);
  });

  test('REAL deliberately accepts SQL INTEGER and requires finite numbers', () {
    expect(Codecs.real.decode(BigInt.from(12)), 12.0);
    expect(Codecs.real.decode(-0.0).isNegative, isTrue);
    expect(Codecs.real.encode(1.25), 1.25);
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity
    ]) {
      expect(() => Codecs.real.encode(value), codecError);
      expect(() => Codecs.real.decode(value), codecError);
    }
    for (final value in ['1.25', 1, null, BigInt.one << 63]) {
      expect(() => Codecs.real.decode(value), codecError);
    }
  });

  test('bool only decodes INTEGER zero and one', () {
    expect(Codecs.boolean.encode(true), BigInt.one);
    expect(Codecs.boolean.encode(false), BigInt.zero);
    expect(Codecs.boolean.decode(BigInt.one), isTrue);
    expect(Codecs.boolean.decode(BigInt.zero), isFalse);
    for (final value in [
      BigInt.two,
      -BigInt.one,
      0,
      1,
      0.0,
      1.0,
      true,
      '1',
      null
    ]) {
      expect(() => Codecs.boolean.decode(value), codecError);
    }
  });

  test('TEXT is exact and preserves arbitrary Unicode and NUL values', () {
    const value = 'a\u0000مرحبا 🐈';
    expect(Codecs.text.decode(Codecs.text.encode(value)), value);
    for (final value in [1, BigInt.one, null, Uint8List(0)]) {
      expect(() => Codecs.text.decode(value), codecError);
    }
  });

  test('nullable wrappers preserve NULL without changing concrete codec rules',
      () {
    final codec = Codecs.nullable(Codecs.bigInt);
    expect(codec.nullable, isTrue);
    expect(codec.sqlType, 'INTEGER');
    expect(codec.encode(null), isNull);
    expect(codec.decode(null), isNull);
    expect(codec.decode(BigInt.one), BigInt.one);
    expect(() => codec.decode('1'), codecError);
    expect(() => Codecs.nullable(codec), throwsA(isA<OrmMappingException>()));
    expect(Codecs.text.nullable, isFalse);
  });

  test('BLOB codecs copy both ownership boundaries', () {
    final bytes = Uint8List.fromList([0, 1, 255]);
    final encoded = Codecs.blob.encode(bytes) as Uint8List;
    encoded[0] = 9;
    expect(bytes, [0, 1, 255]);
    final decoded = Codecs.blob.decode(bytes);
    decoded[1] = 9;
    expect(bytes, [0, 1, 255]);
    expect(() => Codecs.blob.decode([0, 1]), codecError);
  });

  test('DateTime normalizes UTC and strictly decodes canonical microseconds',
      () {
    final value = DateTime.parse('2026-01-02T03:04:05.123456+03:00');
    const stored = '2026-01-02T00:04:05.123456Z';
    expect(Codecs.dateTime.encode(value), stored);
    final decoded = Codecs.dateTime.decode(stored);
    expect(decoded, value.toUtc());
    expect(decoded.isUtc, isTrue);
    for (final invalid in [
      '2026-01-02T00:04:05.123456+00:00',
      '2026-01-02',
      '2026-02-30T00:00:00.000Z',
      '2026-01-02T00:04:05.123456',
      'not a date',
      null,
      0
    ]) {
      expect(() => Codecs.dateTime.decode(invalid), codecError);
    }
  });

  test(
      'encoded SQL helper copies blobs and rejects unsupported/nonfinite values',
      () {
    final bytes = Uint8List.fromList([1, 2]);
    (copyOrmValue(bytes) as Uint8List)[0] = 9;
    expect(bytes, [1, 2]);
    expect(copyOrmValue(12), BigInt.from(12));
    for (final value in [
      Object(),
      true,
      [],
      {},
      double.nan,
      double.infinity,
      BigInt.one << 63
    ]) {
      expect(() => copyOrmValue(value), codecError);
    }
    expect(ormValuesEqual(Uint8List.fromList([1]), Uint8List.fromList([1])),
        isTrue);
    expect(ormValuesEqual(Uint8List.fromList([1]), Uint8List.fromList([2])),
        isFalse);
    expect(ormValuesEqual(Uint8List(0), Uint8List(1)), isFalse);
    expect(ormValuesEqual(null, null), isTrue);
  });

  test('all scalar codecs round-trip through the real Pure Dart engine',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(i INTEGER,r REAL,s TEXT,b BLOB,z INTEGER,d TEXT)');
    final stamp = DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7);
    await db.execute('INSERT INTO t VALUES(?,?,?,?,?,?)', [
      Codecs.bigInt.encode((BigInt.one << 63) - BigInt.one),
      Codecs.real.encode(1.5),
      Codecs.text.encode("A';DROP TABLE t;--"),
      Codecs.blob.encode(Uint8List.fromList([0, 255])),
      Codecs.boolean.encode(true),
      Codecs.dateTime.encode(stamp),
    ]);
    final row = (await db.query('SELECT * FROM t')).rows.single;
    expect(Codecs.bigInt.decode(row[0]), (BigInt.one << 63) - BigInt.one);
    expect(Codecs.real.decode(row[1]), 1.5);
    expect(Codecs.text.decode(row[2]), "A';DROP TABLE t;--");
    expect(Codecs.blob.decode(row[3]), [0, 255]);
    expect(Codecs.boolean.decode(row[4]), isTrue);
    expect(Codecs.dateTime.decode(row[5]), stamp);
  });
}
