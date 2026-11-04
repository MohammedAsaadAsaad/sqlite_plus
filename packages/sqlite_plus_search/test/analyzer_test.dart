import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test('custom language analyzer and dictionary share literal query escaping',
      () {
    const analyzer = _SynonymAnalyzer();
    expect(analyzer.normalize('Infant milk'), 'baby milk');
    expect(analyzer.matchExpression('infant'), '"baby"');
  });

  test('Arabic marks, alef, digits, optional hamza and ya', () {
    const analyzer = SearchTextAnalyzer();
    expect(analyzer.normalize('إِنَّ آلام أَحْمَد ـ ١٢٣ ۴۵۶'),
        'ان الام احمد  123 456');
    expect(analyzer.normalize('على ؤ ئ'), 'علي ؤ ئ');
    expect(const SearchTextAnalyzer(foldYa: false).normalize('على'), 'على');
    expect(const SearchTextAnalyzer(foldHamza: true).normalize('ؤ ئ'), 'و ي');
    expect(analyzer.normalize(''), '');
  });

  test('reuses optional Arabic stemmer while preserving other languages', () {
    const analyzer = SearchTextAnalyzer(stemArabic: true);
    expect(analyzer.normalize('الحديقة حديقة الله Milk 中文 Ελληνικά'),
        'حديق حديق الله milk 中文 ελληνικά');
    expect(analyzer.signature, isNot(const SearchTextAnalyzer().signature));
  });

  test('literal MATCH escapes syntax and does not interpret operators', () {
    const analyzer = SearchTextAnalyzer();
    expect(analyzer.matchExpression('milk OR "tea"'),
        '"milk" OR "or" OR """tea"""');
    expect(analyzer.matchExpression('  '), '');
  });

  test('engine Unicode tokenization and BM25 work with normalized mixed text',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    const analyzer = SearchTextAnalyzer(stemArabic: true);
    await db.execute('CREATE VIRTUAL TABLE f USING fts5(body)');
    for (final text in [
      'حَلِيب Milk',
      'milk with many extra words and water',
      '中文 Ελληνικά',
      'الحديقة'
    ]) {
      await db.execute(
          'INSERT INTO f(body) VALUES (?)', [analyzer.normalize(text)]);
    }
    Future<QueryResult> find(String query) => db.query(
        'SELECT rowid, bm25(f) FROM f WHERE f MATCH ? ORDER BY bm25(f), rowid',
        [analyzer.matchExpression(query)]);
    expect((await find('MILK')).rows.first[0], BigInt.one);
    expect((await find('حليب')).rows.single[0], BigInt.one);
    expect((await find('حديقة')).rows.single[0], BigInt.from(4));
    expect((await find('中文')).rows.single[0], BigInt.from(3));
    expect((await find('Ελληνικά')).rows.single[0], BigInt.from(3));
    expect((await find('missing')).rows, isEmpty);
    expect((await find('milk OR missing')).rows.length, 2);
  });
}

// Application-supplied language rules can include versioned synonym dictionaries.
final class _SynonymAnalyzer extends SearchAnalyzer {
  const _SynonymAnalyzer();
  @override
  String get signature => 'english-fixture-synonyms-v1';
  @override
  String normalize(String text) => const SearchTextAnalyzer()
      .normalize(text)
      .replaceAll(RegExp(r'\binfant\b'), 'baby');
}
