import 'dart:typed_data';

import '../sql/values.dart';

/// SQLite varints and record serialization. Integers must fit signed 64 bits.
abstract final class RecordEncoder {
  static Uint8List varint(BigInt input) {
    var value = input;
    if (value < BigInt.zero || value.bitLength > 64) {
      throw RangeError('Invalid unsigned varint');
    }
    if (value.bitLength > 56) {
      final result = Uint8List(9);
      result[8] = (value & BigInt.from(255)).toInt();
      value >>= 8;
      for (var i = 7; i >= 0; i--) {
        result[i] = (value & BigInt.from(127)).toInt() | 128;
        value >>= 7;
      }
      return result;
    }
    final bytes = [(value & BigInt.from(127)).toInt()];
    while ((value >>= 7) != BigInt.zero) {
      bytes.insert(0, (value & BigInt.from(127)).toInt() | 128);
    }
    return Uint8List.fromList(bytes);
  }

  static Uint8List encode(List<Object?> values, {required int encoding}) {
    if (encoding < 1 || encoding > 3) {
      throw const FormatException('Invalid encoding');
    }
    final serials = BytesBuilder(copy: false);
    final body = BytesBuilder(copy: false);
    for (final original in values) {
      final value = sqlValue(original);
      int serial;
      Uint8List bytes;
      if (value == null) {
        serial = 0;
        bytes = Uint8List(0);
      } else if (value is BigInt) {
        if (value == BigInt.zero || value == BigInt.one) {
          serial = value == BigInt.zero ? 8 : 9;
          bytes = Uint8List(0);
        } else {
          final widths = [1, 2, 3, 4, 6, 8];
          final length = widths.firstWhere((n) =>
              value >= -(BigInt.one << (n * 8 - 1)) &&
              value < BigInt.one << (n * 8 - 1));
          serial = widths.indexOf(length) + 1;
          var unsigned = value.toUnsigned(length * 8);
          bytes = Uint8List(length);
          for (var i = length - 1; i >= 0; i--) {
            bytes[i] = (unsigned & BigInt.from(255)).toInt();
            unsigned >>= 8;
          }
        }
      } else if (value is double) {
        serial = 7;
        bytes = Uint8List(8);
        ByteData.sublistView(bytes).setFloat64(0, value);
      } else {
        bytes = value is String
            ? Uint8List.fromList(encodeSqlText(value, encoding))
            : Uint8List.fromList(value as Uint8List);
        serial = 12 + bytes.length * 2 + (value is String ? 1 : 0);
      }
      serials.add(varint(BigInt.from(serial)));
      body.add(bytes);
    }
    final types = serials.takeBytes();
    var headerSize = types.length + 1;
    while (true) {
      final sizeBytes = varint(BigInt.from(headerSize));
      final computed = types.length + sizeBytes.length;
      if (computed == headerSize) {
        return Uint8List.fromList(
            [...sizeBytes, ...types, ...body.takeBytes()]);
      }
      headerSize = computed;
    }
  }
}
