import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

/// One ranked note. [id] is the source primary key as text.
class ShelfHit {
  const ShelfHit(this.id, {this.keywordRank, this.vectorRank});

  final String id;
  final double? keywordRank;
  final double? vectorRank;
}

/// Prints the shelf in the order a reader meets each idea.
void printClinicShelf(ClinicShelf shelf) {
  print('Pharmacy notes for حليب: ${shelf.pharmacyMilk.join(', ')}');
  print('Every note for حليب: ${shelf.everyMilkNote.join(', ')}');
  print('Tea inserted after the index: ${shelf.teaAddedLater}');
  print('Stemmed حديقة: ${shelf.stemmedGarden.join(', ')}');
  for (final hit in shelf.hybrid) {
    print(
      'Hybrid ${hit.id}  keyword ${hit.keywordRank}  vector ${hit.vectorRank}',
    );
  }
  print('Unknown fixture query rejected: ${shelf.unknownFixtureRejected}');
}

/// What the clinic-shelf walk shows a reader.
class ClinicShelf {
  const ClinicShelf({
    required this.pharmacyMilk,
    required this.everyMilkNote,
    required this.teaAddedLater,
    required this.stemmedGarden,
    required this.hybrid,
    required this.unknownFixtureRejected,
  });

  /// `حليب` on the pharmacy shelf. Diacritics in the stored note do not hide it.
  final List<String> pharmacyMilk;

  /// The same word on every shelf.
  final List<String> everyMilkNote;

  /// A row inserted after indexing. `autoUpdate` makes it searchable.
  final String teaAddedLater;

  /// `حديقة` finds `الحديقة` when Arabic stemming is on.
  final List<String> stemmedGarden;

  /// Fixture vectors, not a language model. Ranks come from `explain: true`.
  final List<ShelfHit> hybrid;

  /// A query missing from the fixture fails instead of inventing a vector.
  final bool unknownFixtureRejected;
}

ShelfHit _hit(SearchHit hit) => ShelfHit(
      hit.documentId,
      keywordRank: hit.explanation?['keywordRank'],
      vectorRank: hit.explanation?['vectorRank'],
    );

/// A clinic keeps short notes. Search reads those rows; it does not copy them.
Future<ClinicShelf> runClinicShelf() async {
  final db = await openInMemory();
  try {
    await db.execute(
      'CREATE TABLE notes('
      'id INTEGER PRIMARY KEY, shelf TEXT NOT NULL, body TEXT)',
    );
    await db.execute(
      'INSERT INTO notes(id, shelf, body) VALUES '
      "(1, 'pharmacy', 'حَلِيب للأطفال'), "
      "(2, 'pharmacy', 'شاي أخضر'), "
      "(3, 'clinic', 'حليب للزيارة')",
    );
    final search = await SqlitePlusSearch.open(database: db);
    await search.indexTable(
      table: 'notes',
      primaryKey: 'id',
      textColumns: ['body'],
      autoUpdate: true,
    );

    final pharmacy = await search.search(
      'حليب',
      table: 'notes',
      filter: SearchFilter('shelf = ?', ['pharmacy']),
    );
    final everyMilk = await search.search('حليب', table: 'notes');
    await db.execute(
      "INSERT INTO notes(id, shelf, body) VALUES (4, 'pharmacy', 'mint tea')",
    );
    final tea = await search.search('tea', table: 'notes');
    await search.verifyIndex(table: 'notes');

    return ClinicShelf(
      pharmacyMilk: [for (final hit in pharmacy.hits) hit.documentId],
      everyMilkNote: [for (final hit in everyMilk.hits) hit.documentId],
      teaAddedLater: tea.hits.single.documentId,
      stemmedGarden: await _garden(db),
      hybrid: await _hybrid(db),
      unknownFixtureRejected: await _rejectsUnknownFixture(db),
    );
  } finally {
    await db.close();
  }
}

Future<List<String>> _garden(MutableSqliteDatabase db) async {
  await db.execute('CREATE TABLE plots(id INTEGER PRIMARY KEY, title TEXT)');
  await db.execute("INSERT INTO plots VALUES (1, 'الحديقة الخلفية')");
  final search = await SqlitePlusSearch.open(
    database: db,
    analyzer: const SearchTextAnalyzer(stemArabic: true),
  );
  await search.indexTable(
    table: 'plots',
    primaryKey: 'id',
    textColumns: ['title'],
  );
  final hits = await search.search('حديقة', table: 'plots');
  return [for (final hit in hits.hits) hit.documentId];
}

Future<List<ShelfHit>> _hybrid(MutableSqliteDatabase db) async {
  await db.execute('CREATE TABLE drinks(id INTEGER PRIMARY KEY, name TEXT)');
  await db.execute(
    'INSERT INTO drinks VALUES '
    "(1, 'fresh milk'), (2, 'green tea'), (3, 'milk powder')",
  );
  // Exact strings only. This map does not understand language.
  final fixture = FixtureEmbeddingProvider(
    modelId: 'clinic-fixture-v1',
    dimensions: 2,
    vectors: {
      'fresh milk': [1, 0],
      'green tea': [0, 1],
      'milk powder': [0.8, 0.2],
    },
  );
  final search = await SqlitePlusSearch.open(
    database: db,
    embeddingProvider: fixture,
  );
  await search.indexTable(
    table: 'drinks',
    primaryKey: 'id',
    textColumns: ['name'],
  );
  final hits = await search.search(
    'fresh milk',
    table: 'drinks',
    mode: SearchMode.hybrid,
    explain: true,
  );
  return [for (final hit in hits.hits) _hit(hit)];
}

Future<bool> _rejectsUnknownFixture(MutableSqliteDatabase db) async {
  final search = await SqlitePlusSearch.open(
    database: db,
    embeddingProvider: FixtureEmbeddingProvider(
      modelId: 'clinic-fixture-v1',
      dimensions: 2,
      vectors: {
        'fresh milk': [1, 0]
      },
    ),
  );
  try {
    await search.search('coffee', table: 'drinks', mode: SearchMode.semantic);
    return false;
  } on StateError {
    return true;
  }
}
