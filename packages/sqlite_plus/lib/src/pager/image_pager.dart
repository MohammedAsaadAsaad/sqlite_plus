import 'dart:typed_data';

/// An exclusively owned, atomic image commit boundary. Images exposed to the
/// SQL layer use rollback-format headers, even when persisted through WAL.
abstract interface class ImagePager {
  Future<Uint8List> readImage();
  Future<void> commitImage(Uint8List image);
  Future<void> close();
}
