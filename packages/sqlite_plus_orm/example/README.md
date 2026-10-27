# reading log

مشروع صغير يشغّل sqlite_plus_orm بأسماء الحقول: كتابان، ومراجعة، ورف JSON، من غير نص SQL.

This example is its own Dart project. It is a workspace member and is not published.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

`lib/reading_log.dart` opens memory through `MutableDatabaseConnection.openMemory`, saves two books, and reads the renamed book with `MappedField.at`. `bin/main.dart` prints the log. `test/reading_log_test.dart` expects revision 1 for the renamed book and revision 0 for the other.
