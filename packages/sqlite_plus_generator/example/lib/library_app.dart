import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

import 'models.dart';

/// The generated library.
///
/// A purchase filter drops the cheap row and orders the rest. A JSON path,
/// an FTS search, and an R-tree intersection each return one of two stored
/// rows. The application calls `sqlite_plus_orm` only.
final class LibraryApp {
  const LibraryApp({
    required this.customer,
    required this.totals,
    required this.matchCount,
    required this.note,
    required this.article,
    required this.placeId,
    required this.insideCount,
    required this.storedPlaces,
    required this.secondPlanEmpty,
  });

  final String customer;
  final List<double> totals;
  final BigInt matchCount;
  final String note;
  final String article;
  final BigInt placeId;
  final int insideCount;
  final int storedPlaces;
  final bool secondPlanEmpty;
}

Future<LibraryApp> runLibraryApp() async {
  final connection = await MutableDatabaseConnection.openMemory();
  final context = DbContext(connection, generatedModel);
  try {
    await context.migrations.ensureCreated();
    final customers = context.set(CustomerMapping.instance);
    final purchases = context.set(PurchaseMapping.instance);
    final notes = context.set(NoteMapping.instance);
    final articles = context.set(ArticleMapping.instance);
    final places = context.set(PlaceMapping.instance);
    final customer = customers.add(Customer(name: 'Ada'));
    final purchase = purchases.add(Purchase(total: 22.5));
    purchases.add(Purchase(total: 4));
    purchases.add(Purchase(total: 30));
    purchase.reference(PurchaseRelationships.customer).set(customer);
    notes.add(Note(document: '{"title":"kept"}'));
    notes.add(Note(document: '{"title":"other"}'));
    articles.add(Article(body: 'alpha kept'));
    articles.add(Article(body: 'beta lost'));
    places.add(Place(id: BigInt.one, minX: 0, maxX: 1, minY: 0, maxY: 1));
    places.add(Place(id: BigInt.two, minX: 5, maxX: 6, minY: 5, maxY: 6));
    if (await context.saveChanges() != 10) {
      throw StateError('library did not save ten rows');
    }
    final matched = purchases.query
        .filter((row) => row.total > 20.0)
        .orderByFields((row) => [row.total.ascending]);
    final rows = await matched.toList();
    final matchCount = await matched.count();
    final note = (await NoteQuery(notes.query)
            .filter((row) => row.path(r'$.title').equalTo('kept'))
            .toList())
        .single;
    final article =
        (await ArticleQuery(articles.query).search('kept').toList()).single;
    final inside = await PlaceQuery(places.query)
        .filter((row) => row.bounds
            .intersects(const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
        .toList();
    final storedPlaces = await places.query.count();
    final buyer =
        await purchase.reference(PurchaseRelationships.customer).load();
    return LibraryApp(
      customer: buyer?.name ?? '',
      totals: [for (final row in rows) row.total],
      matchCount: matchCount,
      note: note.document,
      article: article.body,
      placeId: inside.single.id,
      insideCount: inside.length,
      storedPlaces: storedPlaces.toInt(),
      secondPlanEmpty: (await context.migrations.plan()).isEmpty,
    );
  } finally {
    await context.close();
  }
}
