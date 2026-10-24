import 'dart:convert';
import 'dart:typed_data';

/// A bounded SQLite varint reader. BigInt preserves all 64 bits on every target.
final class SqliteByteReader {
  SqliteByteReader(this.bytes, {this.offset = 0, int? end})
      : end = end ?? bytes.length {
    if (offset < 0 || this.end < offset || this.end > bytes.length) {
      throw RangeError('Invalid reader bounds');
    }
  }

  final Uint8List bytes;
  final int end;
  int offset;

  int byte() {
    if (offset >= end) throw const FormatException('Truncated cell or record');
    return bytes[offset++];
  }

  BigInt varint() {
    var result = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      final value = byte();
      result = (result << 7) | BigInt.from(value & 127);
      if (value < 128) return result;
    }
    return (result << 8) | BigInt.from(byte());
  }

  int uint32() =>
      (byte() * 0x1000000) + (byte() << 16) + (byte() << 8) + byte();
}

/// SQLite record values: null, BigInt, double, String, or copied Uint8List.
/// Integer values deliberately use BigInt, including the constants 0 and 1.
abstract final class RecordCodec {
  static List<Object?> decode(Uint8List payload, {required int encoding}) {
    if (encoding < 1 || encoding > 3) {
      throw const FormatException('Uninitialized or unsupported text encoding');
    }
    final reader = SqliteByteReader(payload);
    final headerSizeValue = reader.varint();
    if (headerSizeValue > BigInt.from(payload.length) ||
        headerSizeValue < BigInt.from(reader.offset)) {
      throw const FormatException('Invalid record header length');
    }
    final headerSize = headerSizeValue.toInt();
    final header =
        SqliteByteReader(payload, offset: reader.offset, end: headerSize);
    var body = headerSize;
    final values = <Object?>[];
    while (header.offset < headerSize) {
      final serial = header.varint();
      if (serial == BigInt.from(10) || serial == BigInt.from(11)) {
        throw const FormatException('Reserved record serial type');
      }
      final int length;
      if (serial < BigInt.from(12)) {
        length = const [0, 1, 2, 3, 4, 6, 8, 8, 0, 0][serial.toInt()];
      } else {
        final size = (serial - BigInt.from(12)) >> 1;
        if (size > BigInt.from(payload.length - body)) {
          throw const FormatException('Record field exceeds payload');
        }
        length = size.toInt();
      }
      if (body + length > payload.length) {
        throw const FormatException('Truncated record body');
      }
      final type = serial < BigInt.from(12) ? serial.toInt() : 12;
      Object? value;
      if (type >= 1 && type <= 6) {
        var integer = BigInt.zero;
        for (var i = 0; i < length; i++) {
          integer = (integer << 8) | BigInt.from(payload[body + i]);
        }
        value = integer.toSigned(length * 8);
      } else if (type == 7) {
        value = ByteData.sublistView(payload).getFloat64(body);
      } else if (type == 8 || type == 9) {
        value = BigInt.from(type - 8);
      } else if (type == 12) {
        final bytes = Uint8List.sublistView(payload, body, body + length);
        value =
            serial.isEven ? Uint8List.fromList(bytes) : _text(bytes, encoding);
      }
      values.add(value);
      body += length;
    }
    if (body != payload.length) {
      throw const FormatException('Trailing record bytes');
    }
    return List.unmodifiable(values);
  }

  static String _text(Uint8List bytes, int encoding) {
    if (encoding == 1) return utf8.decode(bytes);
    if (bytes.length.isOdd) {
      throw const FormatException('Odd UTF-16 byte length');
    }
    final data = ByteData.sublistView(bytes);
    final endian = encoding == 2 ? Endian.little : Endian.big;
    final units = <int>[];
    for (var i = 0; i < bytes.length; i += 2) {
      final unit = data.getUint16(i, endian);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (i + 3 >= bytes.length) {
          throw const FormatException('Unpaired UTF-16 surrogate');
        }
        final low = data.getUint16(i + 2, endian);
        if (low < 0xdc00 || low > 0xdfff) {
          throw const FormatException('Unpaired UTF-16 surrogate');
        }
        units.addAll([unit, low]);
        i += 2;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('Unpaired UTF-16 surrogate');
      } else {
        units.add(unit);
      }
    }
    return String.fromCharCodes(units);
  }
}
