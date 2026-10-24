import 'dart:typed_data';

/// Byte-addressed storage; concrete backends define their durability guarantees.
abstract interface class StorageBackend {
  Future<int> read(int offset, Uint8List buffer);
  Future<void> write(int offset, Uint8List bytes);
  Future<void> truncate(int size);
  Future<int> length();
  Future<void> sync();
  Future<void> close();
}
