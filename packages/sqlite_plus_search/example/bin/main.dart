import 'package:sqlite_plus_search_example/clinic_shelf.dart';

Future<void> main() async {
  printClinicShelf(await runClinicShelf());
}
