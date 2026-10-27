import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryStorageBackend', () {
    test('starts empty', () async {
      final storage = MemoryStorageBackend();
      expect(await storage.length(), 0);
      await storage.close();
    });

    test('write, sparse zero fill and partial reads', () async {
      final storage = MemoryStorageBackend();
      await storage.write(3, Uint8List.fromList([5, 6]));
      expect(await storage.length(), 5);
      final data = Uint8List(8);
      expect(await storage.read(0, data), 5);
      expect(data.sublist(0, 5), [0, 0, 0, 5, 6]);
      expect(await storage.read(5, Uint8List(2)), 0);
      await storage.close();
    });

    test('truncate shrinks and grows with zeros', () async {
      final storage = MemoryStorageBackend();
      await storage.write(0, Uint8List.fromList([1, 2, 3]));
      await storage.truncate(2);
      await storage.truncate(4);
      final data = Uint8List(4);
      expect(await storage.read(0, data), 4);
      expect(data, [1, 2, 0, 0]);
      await storage.close();
    });

    test('rejects invalid offsets and closed access', () async {
      final storage = MemoryStorageBackend();
      await expectLater(storage.write(-1, Uint8List(1)), throwsRangeError);
      await expectLater(storage.read(-1, Uint8List(1)), throwsRangeError);
      await expectLater(storage.truncate(-1), throwsRangeError);
      await storage.close();
      await expectLater(storage.length(), throwsStateError);
      await expectLater(storage.sync(), throwsStateError);
    });

    test('read-only image view aliases the caller buffer', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final storage = ByteImageStorage(bytes);
      final window = Uint8List(2);
      expect(await storage.read(1, window), 2);
      expect(window, [2, 3]);
      bytes[1] = 9;
      final all = Uint8List(4);
      expect(await storage.read(0, all), 4);
      expect(all, [1, 9, 3, 4]);
      expect(await storage.length(), 4);
      await storage.sync();
      await expectLater(storage.write(0, Uint8List(1)), throwsStateError);
      await expectLater(storage.truncate(1), throwsStateError);
      await expectLater(storage.read(-1, Uint8List(1)), throwsRangeError);
      await expectLater(storage.truncate(-1), throwsRangeError);
      await storage.close();
      await expectLater(storage.length(), throwsStateError);
      await expectLater(storage.read(0, all), throwsStateError);
      expect(bytes, [1, 9, 3, 4]);
    });

    test('stores an independent copy of written bytes', () async {
      final storage = MemoryStorageBackend();
      final input = Uint8List.fromList([7, 8]);
      await storage.write(0, input);
      input[0] = 99;
      final output = Uint8List(2);
      await storage.read(0, output);
      expect(output, [7, 8]);
      await storage.close();
    });
  });
}
