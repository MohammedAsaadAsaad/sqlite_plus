import 'dart:convert';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

void main() {
  test('ArabicText folds digits and optional letters, then stems Arabic runs',
      () {
    expect(ArabicText.normalize('إِنَّ آلام أَحْمَد ـ ١٢٣ ۴۵۶'),
        'ان الام احمد  123 456');
    expect(ArabicText.normalize('على ؤ ئ'), 'علي ؤ ئ');
    expect(ArabicText.normalize('على', foldYa: false), 'على');
    expect(ArabicText.normalize('ؤ ئ', foldHamza: true), 'و ي');
    expect(ArabicText.normalize(''), '');
    expect(
        ArabicText.normalize('الحديقة حديقة الله Milk 中文 Ελληνικά', stem: true),
        'حديق حديق الله milk 中文 ελληνικά');
    expect(ArabicTokenizer(const []).tokenize('حديقة').single.text,
        ArabicTokenizer(const []).tokenize('الحديقة').single.text);
  });

  test('stems articles, suffixes, diacritics, and alef variants', () {
    final tokenizer = ArabicTokenizer(const []);
    expect(_stems(tokenizer, 'حديقة'), _stems(tokenizer, 'الحديقة'));
    expect(_stems(tokenizer, 'بالحديقة'), _stems(tokenizer, 'حديقة'));
    expect(_stems(tokenizer, 'والكتاب'), ['كتاب']);
    expect(_stems(tokenizer, 'الكتاب'), ['كتاب']);
    expect(_stems(tokenizer, 'كتابه'), ['كتاب']);
    expect(_stems(tokenizer, 'كِتَابٌ'), ['كتاب']);
    expect(_stems(tokenizer, 'أحمد'), _stems(tokenizer, 'احمد'));
    expect(_stems(tokenizer, 'الله'), ['الله']);
    expect(_stems(tokenizer, 'Hello حديقة'),
        ['hello', _stems(tokenizer, 'حديقة').single]);
    expect(tokenizer.tokenize('').map((token) => token.text), isEmpty);
    expect(tokenizer.tokenize('،،').map((token) => token.text), isEmpty);
    expect(
        () => ArabicTokenizer(const ['remove_diacritics', '1']),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'error in tokenizer constructor')));
  });

  test('MATCH finds the stemmed word and misses an unrelated word', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await expectLater(
        database.execute(
            "CREATE VIRTUAL TABLE docs USING fts5(body, tokenize = 'arabic')"),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'no such tokenizer: arabic')));
    SqlitePlusArabic.register(database);
    SqlitePlusArabic.register(database);
    await database.execute(
        "CREATE VIRTUAL TABLE docs USING fts5(body, tokenize = 'arabic')");
    await database.execute(
        'INSERT INTO docs(body) VALUES (?), (?)', ['في الحديقة', 'سيارة']);
    final found =
        await database.query("SELECT body FROM docs WHERE docs MATCH 'حديقة'");
    expect(found.rows, [
      ['في الحديقة']
    ]);
    final missed =
        await database.query("SELECT body FROM docs WHERE docs MATCH 'كتاب'");
    expect(missed.rows, isEmpty);
  });

  test('the ORM search uses the arabic tokenizer constant', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    SqlitePlusArabic.register(database);
    final connection = MutableDatabaseConnection(database);
    final context = DbContext(connection, DbModel([_mapping.type]));
    await context.migrations.ensureCreated();
    final notes = context.set(_mapping.type);
    notes.add(_Note(body: 'في الحديقة'));
    notes.add(_Note(body: 'سيارة'));
    expect(await context.saveChanges(), 2);
    final found = await notes.query.search('الحديقة').toList();
    expect(found.map((note) => note.body), ['في الحديقة']);
    final sql = await database
        .query("SELECT sql FROM sqlite_schema WHERE name = 'notes'");
    expect(sql.rows.single.single, contains("tokenize = 'arabic'"));
    final again = await context.migrations.plan();
    expect(again.isEmpty, isTrue);
  });
}

List<String> _stems(ArabicTokenizer tokenizer, String text) => tokenizer
    .tokenize(text)
    .map((token) => utf8.decode(token.text.codeUnits))
    .toList();

final class _Note {
  _Note({this.rowid, required this.body});
  BigInt? rowid;
  String body;
}

final _mapping = _NoteMapping();

final class _NoteMapping {
  _NoteMapping() {
    rowid = Column<_Note, BigInt?>(
        property: 'rowid',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (note) => note.rowid,
        write: (note, value) => note.rowid = value,
        keyOrder: 0,
        generated: true);
    body = Column<_Note, String>(
        property: 'body',
        codec: Codecs.text,
        read: (note) => note.body,
        write: (note, value) => note.body = value);
    type = EntityType<_Note>(
        tableName: 'notes',
        columns: [rowid, body],
        virtualModule: DbModules.fts5,
        tokenizer: ArabicTokenizers.arabic,
        create: (row) => _Note(rowid: row.read(rowid), body: row.read(body)));
  }

  late final Column<_Note, BigInt?> rowid;
  late final Column<_Note, String> body;
  late final EntityType<_Note> type;
}
