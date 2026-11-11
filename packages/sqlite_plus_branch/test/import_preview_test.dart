import 'package:test/test.dart';
import '../example/import_preview.dart' as example;

void main() {
  test('prepared ORM import runs on branch and only reviewed result is merged',
      example.main);
}
