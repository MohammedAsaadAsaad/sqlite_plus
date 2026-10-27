# generated library

A small project for the generated mappings: a purchase filter, a JSON path, an FTS search, and R-tree bounds. The application calls the ORM only.

This example is its own Dart project and a workspace member. It stays in the repository. Publication of the packages is planned. `lib/models.orm.g.dart` is checked in.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run sqlite_plus_generator --input lib/models.dart --check
dart run bin/main.dart
```

`lib/models.dart` declares the customer, purchase, JSON note, FTS article, and R-tree place. `lib/library_app.dart` saves them through `generatedModel`. `bin/main.dart` prints the result. `test/library_app_test.dart` expects Ada, totals 22.5 then 30.0, and place 1 of two stored places.
