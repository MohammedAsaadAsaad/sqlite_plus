import 'orm_file_handle.dart';

/// Web stand-in. [DbSet.openDbFile] reports that a file database needs dart:io.
Future<OrmFileHandle> openOrmFile(String path,
    {bool directoryEntriesDurable = true}) async {
  throw UnsupportedError(
      'DbSet.openDbFile requires dart:io for $path (directoryEntriesDurable: $directoryEntriesDurable)');
}
