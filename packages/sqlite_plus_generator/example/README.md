# generated library

مشروع صغير يستهلك الخرائط المولَّدة: مرشح مشتريات، ومسار JSON، وبحث FTS، وحدود R-tree. التطبيق يستدعي ORM فقط.

This example is its own Dart project. It is a workspace member and is not published. `lib/models.orm.g.dart` is checked in.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run sqlite_plus_generator --input lib/models.dart --check
dart run bin/main.dart
```

`lib/models.dart` declares the customer, purchase, JSON note, FTS article, and R-tree place. `lib/library_app.dart` saves them through `generatedModel`. `bin/main.dart` prints the result. `test/library_app_test.dart` expects Ada, totals 22.5 then 30.0, and place 1 of two stored places.
