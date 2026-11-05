/// File databases use [DbSet.openDbFile] from `sqlite_plus_orm.dart`.
///
/// This library exports that API. The file implementation is selected when
/// `dart:io` is available. On the Web [DbSet.openDbFile] throws
/// [UnsupportedError].
library;

export 'sqlite_plus_orm.dart';
