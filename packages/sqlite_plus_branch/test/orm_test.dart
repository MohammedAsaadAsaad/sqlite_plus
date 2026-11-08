import 'package:test/test.dart';
import '../example/orm.dart' as example;

void main() {
  test(
      'ORM direct writes on isolated branch, then read with fresh main context',
      example.main);
}
