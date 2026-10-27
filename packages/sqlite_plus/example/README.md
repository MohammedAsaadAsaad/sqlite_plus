# library tour

A small project for the sqlite_plus engine: bound JSON, a rolled-back transaction, FTS5, an Arabic token, an R-tree query, and reopening the exported image.

This example is its own Dart project and a workspace member. It stays in the repository. Publication of the packages is planned.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

`lib/library_tour.dart` builds one in-memory library. `bin/main.dart` prints the tour. `test/library_tour_test.dart` checks the kept card, the highlighted match, the Arabic token, the shelf inside the unit box, and `user_version` 7 after `exportImage`.
