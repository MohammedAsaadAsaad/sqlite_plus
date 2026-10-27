import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

part 'models.orm.g.dart';

class Customer {
  Customer({this.id, required this.name, this.revision = 0});

  final BigInt? id;
  final String name;
  @DbVersion()
  final int revision;
}

class Purchase {
  Purchase({this.id, this.customerId, required this.total});

  BigInt? id;
  BigInt? customerId;
  double total;
}

class Note {
  Note({this.id, required this.document});

  final BigInt? id;
  @DbJson()
  final String document;
}

@DbEntity(module: 'fts5')
class Article {
  Article({this.rowid, required this.body});

  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}

@DbEntity(module: 'rtree')
class Place {
  Place({
    required this.id,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  final BigInt id;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
}
