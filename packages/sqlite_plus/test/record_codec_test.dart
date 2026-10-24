import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

List<int> varint(BigInt value) {
  final max = (BigInt.one << 64) - BigInt.one;
  if (value < BigInt.zero || value > max) throw RangeError('varint');
  if (value >= (BigInt.one << 56)) {
    final tail = (value & BigInt.from(255)).toInt();
    value >>= 8;
    final prefix = List<int>.filled(8, 0);
    for (var i = 7; i >= 0; i--) {
      prefix[i] = (value & BigInt.from(127)).toInt() | 128;
      value >>= 7;
    }
    return [...prefix, tail];
  }
  final bytes = [(value & BigInt.from(127)).toInt()];
  while ((value >>= 7) != BigInt.zero) {
    bytes.insert(0, (value & BigInt.from(127)).toInt() | 128);
  }
  return bytes;
}

void main() {
  List<Object?> decode(List<int> bytes, {int encoding = 1}) =>
      RecordCodec.decode(Uint8List.fromList(bytes), encoding: encoding);

  test('varints at every length boundary including all 64 bits', () {
    final values = <BigInt>{BigInt.zero, (BigInt.one << 64) - BigInt.one};
    for (var bits = 7; bits <= 56; bits += 7) {
      values.addAll([(BigInt.one << bits) - BigInt.one, BigInt.one << bits]);
    }
    for (final value in values) {
      final reader = SqliteByteReader(Uint8List.fromList(varint(value)));
      expect(reader.varint(), value);
      expect(reader.offset, reader.end);
    }
    final unsigned =
        SqliteByteReader(Uint8List.fromList(List.filled(9, 255))).varint();
    expect(unsigned.toSigned(64), -BigInt.one);
  });
  test('truncated varints are format errors, not range errors', () {
    for (var count = 0; count < 9; count++) {
      expect(
          () => SqliteByteReader(Uint8List.fromList(List.filled(count, 128)))
              .varint(),
          throwsFormatException);
    }
    expect(() => SqliteByteReader(Uint8List(1), offset: -1), throwsRangeError);
  });
  test('all integer serial widths, signs, constants, and null', () {
    expect(decode([4, 0, 8, 9]), [null, BigInt.zero, BigInt.one]);
    for (var serial = 1; serial <= 6; serial++) {
      final width = [0, 1, 2, 3, 4, 6, 8][serial];
      expect(decode([2, serial, ...List.filled(width, 255)]), [-BigInt.one]);
      expect(decode([2, serial, 128, ...List.filled(width - 1, 0)]),
          [-(BigInt.one << (width * 8 - 1))]);
      expect(decode([2, serial, 127, ...List.filled(width - 1, 255)]),
          [(BigInt.one << (width * 8 - 1)) - BigInt.one]);
    }
  });
  test('big-endian float64, infinity and NaN', () {
    for (final value in [-0.0, 1.25, double.infinity, double.nan]) {
      final bytes = Uint8List(10)
        ..[0] = 2
        ..[1] = 7;
      ByteData.sublistView(bytes).setFloat64(2, value);
      final result = RecordCodec.decode(bytes, encoding: 1).single as double;
      if (value.isNaN) {
        expect(result.isNaN, isTrue);
      } else {
        expect(result, value);
        if (value == 0) expect(result.isNegative, isTrue);
      }
    }
  });
  test('UTF encodings, surrogate pairs, empty values and independent blobs',
      () {
    expect(decode([3, 12, 13]), [Uint8List(0), '']);
    final text = utf8.encode('λ😀');
    expect(decode([2, 13 + 2 * text.length, ...text]), ['λ😀']);
    for (final encoding in [2, 3]) {
      final bytes = Uint8List(8)
        ..[0] = 2
        ..[1] = 25;
      final data = ByteData.sublistView(bytes);
      final endian = encoding == 2 ? Endian.little : Endian.big;
      data.setUint16(2, 0x03bb, endian);
      data.setUint16(4, 0xd83d, endian);
      data.setUint16(6, 0xde00, endian);
      expect(RecordCodec.decode(bytes, encoding: encoding), ['λ😀']);
    }
    final bytes = Uint8List.fromList([2, 16, 1, 2]);
    final values = RecordCodec.decode(bytes, encoding: 1);
    bytes[2] = 99;
    expect(values.single, [1, 2]);
    expect(() => values.add(null), throwsUnsupportedError);
  });
  test('multi-byte header size and serial type', () {
    final payload = Uint8List.fromList([129, 2, ...List.filled(128, 0)]);
    expect(RecordCodec.decode(payload, encoding: 1), List.filled(128, null));
    final text = List.filled(128, 97);
    expect(decode([3, 130, 13, ...text]), ['a' * 128]);
  });
  test('record corruption, reserved serials and malformed text fail', () {
    for (final bytes in <List<int>>[
      [],
      [0],
      [2],
      [3, 0],
      [1, 0],
      [2, 10],
      [2, 11],
      [2, 6],
      [2, 255],
      [2, 17, 65],
      [2, 15, 255],
      [2, 12, 0],
    ]) {
      expect(() => decode(bytes), throwsFormatException, reason: '$bytes');
    }
    for (final text in <List<int>>[
      [0],
      [0, 216],
      [0, 220],
      [0, 216, 65, 0]
    ]) {
      expect(() => decode([2, 13 + 2 * text.length, ...text], encoding: 2),
          throwsFormatException);
    }
    expect(() => decode([1], encoding: 0), throwsFormatException);
    expect(() => decode([1], encoding: 4), throwsFormatException);
  });
  test('deterministic malformed-record fuzz never leaks bounds errors', () {
    final random = Random(2319);
    for (var i = 0; i < 2000; i++) {
      final bytes = Uint8List.fromList(
          List.generate(random.nextInt(100), (_) => random.nextInt(256)));
      try {
        RecordCodec.decode(bytes, encoding: 1 + random.nextInt(3));
      } on FormatException {
        // Expected rejection; RangeError and other exceptions must fail this test.
      }
    }
  });
}
