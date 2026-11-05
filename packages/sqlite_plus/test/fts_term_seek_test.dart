import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('packed leaves find every copy of a term, including a split posting',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE VIRTUAL TABLE t USING fts5(body)');
    const copies = 1200;
    final values = List.filled(copies + 2, '(?)').join(',');
    final texts = [
      for (var i = 0; i < copies; i++) 'common word$i',
      'other',
      'common extra',
    ];
    await db.execute('INSERT INTO t(body) VALUES $values', texts);
    final terms =
        await db.query('SELECT count(*), min(length(term)) FROM t_idx');
    expect(terms.rows.single[0], greaterThan(BigInt.one));
    expect(terms.rows.single[1], greaterThan(BigInt.zero));

    final hits = await db.query(
        "SELECT rowid, bm25(t) FROM t WHERE t MATCH 'common' ORDER BY rowid");
    expect(hits.rows, hasLength(copies + 1));
    expect(hits.rows.first[0], BigInt.one);
    expect(hits.rows.last[0], BigInt.from(copies + 2));
    final scores = [for (final row in hits.rows) row[1]].cast<double>();
    expect(scores.first, scores[1]);
    expect(scores.every((score) => score.isFinite && score < 0), isTrue);

    final both =
        await db.query("SELECT count(*) FROM t WHERE t MATCH 'common extra'");
    expect(both.rows.single.single, BigInt.one);
    final either = await db
        .query("SELECT count(*) FROM t WHERE t MATCH 'other OR missing'");
    expect(either.rows.single.single, BigInt.one);
    final marked = await db
        .query("SELECT highlight(t, 0, '<', '>') FROM t WHERE t MATCH 'other'");
    expect(marked.rows.single.single, '<other>');
  });

  test('a packed external-content index ranks one page of rowids', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE keys(id INTEGER PRIMARY KEY, body TEXT, source_key TEXT)');
    for (var i = 1; i <= 40; i++) {
      await db.execute('INSERT INTO keys(body, source_key) VALUES (?, ?)',
          [i.isEven ? 'milk $i' : 'tea $i', '$i']);
    }
    await db.execute(
        "CREATE VIRTUAL TABLE f USING fts5(body, content='keys', content_rowid='id')");
    await db.execute("INSERT INTO f(f) VALUES ('rebuild')");
    final hits = await db.query(
        "SELECT rowid, bm25(f) FROM f WHERE f MATCH 'milk' ORDER BY rowid");
    expect(hits.rows, hasLength(20));
    expect(hits.rows.first[0], BigInt.two);
    expect(hits.rows.every((row) => row[1] is double && (row[1] as double) < 0),
        isTrue);
  });
}
