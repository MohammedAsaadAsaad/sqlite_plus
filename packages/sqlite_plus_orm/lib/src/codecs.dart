part of '../sqlite_plus_orm.dart';

/// Converts one Dart value to a SQLite storage value and back.
abstract class ValueCodec<V> {
  /// A codec with no stored configuration.
  const ValueCodec();

  /// `INTEGER`, `REAL`, `TEXT`, or `BLOB`.
  String get sqlType;

  /// Whether SQL `NULL` is a valid stored value.
  bool get nullable => false;

  /// Converts [value] to a SQLite storage value.
  Object? encode(V value);

  /// Converts a SQLite storage value back to [V].
  V decode(Object? value);
}

/// Built-in codecs for the seven mapped Dart types.
abstract final class Codecs {
  /// Signed 64-bit integer stored as `INTEGER`.
  static const ValueCodec<BigInt> bigInt = _BigIntCodec();

  /// Portable 53-bit integer stored as `INTEGER`.
  static const ValueCodec<int> integer = _IntegerCodec();

  /// Finite double stored as `REAL`.
  static const ValueCodec<double> real = _RealCodec();

  /// Text stored as `TEXT`.
  static const ValueCodec<String> text = _TextCodec();

  /// `true` and `false` stored as integers `1` and `0`.
  static const ValueCodec<bool> boolean = _BooleanCodec();

  /// A copied byte list stored as `BLOB`.
  static const ValueCodec<Uint8List> blob = _BlobCodec();

  /// UTC timestamp stored as `TEXT`.
  static const ValueCodec<DateTime> dateTime = _DateTimeCodec();

  /// Wraps [codec] so SQL `NULL` decodes as null.
  static ValueCodec<V?> nullable<V>(ValueCodec<V> codec) {
    if (codec.nullable) {
      throw const OrmMappingException('Codec is already nullable');
    }
    return _NullableCodec<V>(codec);
  }
}

final _ormMinInteger = -(BigInt.one << 63);
final _ormMaxInteger = (BigInt.one << 63) - BigInt.one;
final _ormMaxPortableInteger = BigInt.from(9007199254740991);

BigInt _ormCheckedInteger(BigInt value) {
  if (value < _ormMinInteger || value > _ormMaxInteger) {
    throw const OrmCodecException('INTEGER is outside signed 64-bit range');
  }
  return value;
}

final class _BigIntCodec extends ValueCodec<BigInt> {
  const _BigIntCodec();
  @override
  String get sqlType => 'INTEGER';
  @override
  Object encode(BigInt value) => _ormCheckedInteger(value);
  @override
  BigInt decode(Object? value) {
    if (value is! BigInt) {
      throw const OrmCodecException('Expected SQL INTEGER');
    }
    return _ormCheckedInteger(value);
  }
}

final class _IntegerCodec extends ValueCodec<int> {
  const _IntegerCodec();
  @override
  String get sqlType => 'INTEGER';
  @override
  Object encode(int value) => _check(BigInt.from(value));
  BigInt _check(BigInt value) {
    if (value.abs() > _ormMaxPortableInteger) {
      throw const OrmCodecException('int is outside portable 53-bit range');
    }
    return value;
  }

  @override
  int decode(Object? value) {
    if (value is! BigInt) {
      throw const OrmCodecException('Expected SQL INTEGER');
    }
    return _check(value).toInt();
  }
}

final class _RealCodec extends ValueCodec<double> {
  const _RealCodec();
  @override
  String get sqlType => 'REAL';
  double _check(double value) {
    if (!value.isFinite) {
      throw const OrmCodecException('REAL must be finite');
    }
    return value;
  }

  @override
  Object encode(double value) => _check(value);
  @override
  double decode(Object? value) {
    if (value is BigInt) return _check(_ormCheckedInteger(value).toDouble());
    if (value is! double) {
      throw const OrmCodecException('Expected SQL REAL or INTEGER');
    }
    return _check(value);
  }
}

final class _TextCodec extends ValueCodec<String> {
  const _TextCodec();
  @override
  String get sqlType => 'TEXT';
  @override
  Object encode(String value) => value;
  @override
  String decode(Object? value) {
    if (value is! String) throw const OrmCodecException('Expected SQL TEXT');
    return value;
  }
}

final class _BooleanCodec extends ValueCodec<bool> {
  const _BooleanCodec();
  @override
  String get sqlType => 'INTEGER';
  @override
  Object encode(bool value) => value ? BigInt.one : BigInt.zero;
  @override
  bool decode(Object? value) {
    if (value is! BigInt) {
      throw const OrmCodecException('Expected INTEGER 0 or 1 for bool');
    }
    if (value == BigInt.zero) return false;
    if (value == BigInt.one) return true;
    throw const OrmCodecException('Expected INTEGER 0 or 1 for bool');
  }
}

final class _BlobCodec extends ValueCodec<Uint8List> {
  const _BlobCodec();
  @override
  String get sqlType => 'BLOB';
  @override
  Object encode(Uint8List value) => Uint8List.fromList(value);
  @override
  Uint8List decode(Object? value) {
    if (value is! Uint8List) {
      throw const OrmCodecException('Expected SQL BLOB');
    }
    return Uint8List.fromList(value);
  }
}

final class _DateTimeCodec extends ValueCodec<DateTime> {
  const _DateTimeCodec();
  @override
  String get sqlType => 'TEXT';
  @override
  Object encode(DateTime value) => value.toUtc().toIso8601String();
  @override
  DateTime decode(Object? value) {
    if (value is! String) {
      throw const OrmCodecException('Expected canonical UTC datetime TEXT');
    }
    final parsed = DateTime.tryParse(value)?.toUtc();
    if (parsed == null || parsed.toIso8601String() != value) {
      throw const OrmCodecException('Expected canonical UTC datetime TEXT');
    }
    return parsed;
  }
}

final class _NullableCodec<V> extends ValueCodec<V?> {
  const _NullableCodec(this.wrapped);
  final ValueCodec<V> wrapped;
  @override
  String get sqlType => wrapped.sqlType;
  @override
  bool get nullable => true;
  @override
  Object? encode(V? value) => value == null ? null : wrapped.encode(value);
  @override
  V? decode(Object? value) => value == null ? null : wrapped.decode(value);
}

ValueCodec<dynamic> _ormBaseCodec(ValueCodec<dynamic> codec) =>
    codec is _NullableCodec ? codec.wrapped : codec;

bool _ormIntegerCodec(ValueCodec<dynamic> codec) =>
    _ormBaseCodec(codec) is _IntegerCodec ||
    _ormBaseCodec(codec) is _BigIntCodec;

/// Copy an encoded SQL value and reject unsupported or lossy values.
Object? copyOrmValue(Object? value) {
  if (value is int) value = BigInt.from(value);
  if (value is BigInt) return _ormCheckedInteger(value);
  if (value is Uint8List) return Uint8List.fromList(value);
  if (value is double) {
    if (!value.isFinite) {
      throw const OrmCodecException('SQL REAL must be finite');
    }
    return value;
  }
  if (value == null || value is String) return value;
  throw const OrmCodecException('Unsupported encoded SQL value');
}

bool ormValuesEqual(Object? left, Object? right) {
  if (left is Uint8List && right is Uint8List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
  return left == right;
}
