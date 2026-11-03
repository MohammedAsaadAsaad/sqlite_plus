import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class Card {
  Card({required this.title, required this.pages, this.tags = const []});
  final String title;
  final int pages;
  final List<String> tags;
  static int decoded = 0;

  Map<String, Object?> toJson() => {
        'title': title,
        'pages': pages,
        'tags': tags,
        'meta': {'ok': true, 'label': null},
      };

  factory Card.fromJson(Map<String, Object?> json) {
    decoded++;
    final meta = json['meta']! as Map<String, Object?>;
    if (meta['ok'] != true ||
        meta.containsKey('label') && meta['label'] != null) {
      throw StateError('meta');
    }
    return Card(
      title: json['title']! as String,
      pages: json['pages']! as int,
      tags: [for (final tag in json['tags']! as List) tag as String],
    );
  }
}

final class Note {
  Note({this.id, required this.card, this.revision = 0});
  BigInt? id;
  Card card;
  int revision;
}

final _cardCodec = Codecs.document(Card.fromJson, (card) => card.toJson());

final class _Notes {
  _Notes() {
    id = Column(
      property: 'id',
      codec: Codecs.nullable(Codecs.bigInt),
      read: (note) => note.id,
      write: (note, value) => note.id = value,
      keyOrder: 0,
      generated: true,
    );
    card = Column(
      property: 'card',
      codec: _cardCodec,
      read: (note) => note.card,
      write: (note, value) => note.card = value,
    );
    revision = Column(
      property: 'revision',
      codec: Codecs.integer,
      read: (note) => note.revision,
      write: (note, value) => note.revision = value,
      version: true,
    );
    type = EntityType(
      tableName: 'notes',
      columns: [id, card, revision],
      create: (row) => Note(
        id: row.read(id),
        card: row.read(card),
        revision: row.read(revision),
      ),
    );
  }

  late final Column<Note, BigInt?> id;
  late final Column<Note, Card> card;
  late final Column<Note, int> revision;
  late final EntityType<Note> type;
}

void main() {
  test('a document codec round-trips an object and rejects bad JSON', () {
    final stored = _cardCodec.encode(
      Card(title: 'Kept Garden', pages: 320, tags: ['margin']),
    );
    expect(stored, isA<String>());
    expect(stored, contains('"pages":320'));
    Card.decoded = 0;
    final card = _cardCodec.decode(stored);
    expect(Card.decoded, 1);
    expect(card.title, 'Kept Garden');
    expect(card.pages, 320);
    expect(card.tags, ['margin']);
    final nullable = Codecs.nullable(_cardCodec);
    expect(nullable.encode(null), isNull);
    expect(nullable.decode(null), isNull);
    expect(
      () => Codecs.document<Object>((json) => json, (value) => 'text')
          .encode(Object()),
      throwsA(isA<OrmCodecException>()),
    );
    expect(
      () => Codecs.document<Object>((json) => json, (value) => {1: 'a'})
          .encode(Object()),
      throwsA(isA<OrmCodecException>()),
    );
    expect(
      () => Codecs.document<Object>(
        (json) => json,
        (value) => {'n': double.nan},
      ).encode(Object()),
      throwsA(isA<OrmCodecException>()),
    );
    expect(
      () => _cardCodec.decode('[]'),
      throwsA(isA<OrmCodecException>()),
    );
    expect(
      () => _cardCodec.decode('{'),
      throwsA(isA<OrmCodecException>()),
    );
    expect(
      () => _cardCodec.decode(1),
      throwsA(isA<OrmCodecException>()),
    );
    expect(
      () => _cardCodec.decode('{"title":1,"pages":1,"tags":[]}'),
      throwsA(isA<OrmCodecException>()),
    );
  });

  test('a document path is bound and only the matching row is decoded',
      () async {
    final notes = _Notes();
    final card = DocumentField(notes.card);
    final database = await MutableSqliteDatabase.create();
    final connection = MutableDatabaseConnection(database);
    final context = DbContext(connection, DbModel([notes.type]));
    addTearDown(context.close);
    await context.migrations.ensureCreated();
    final plan = await context.migrations.plan();
    expect(plan.operations, isEmpty);
    expect(plan.targetSchema, contains('"document":true'));
    final created = context.set(notes.type);
    created.add(Note(card: Card(title: 'Kept Garden', pages: 320)));
    created.add(Note(card: Card(title: 'Other Atlas', pages: 40)));
    expect(await context.saveChanges(), 2);
    final command = created.query
        .where(card.path(r'$.title').equalTo('Kept Garden'))
        .toSql();
    expect(command.sql, contains('json_extract("card", ?) = ?'));
    expect(command.sql.contains(r'$.title'), isFalse);
    expect(command.sql.contains('Kept Garden'), isFalse);
    expect(command.parameters, [r'$.title', 'Kept Garden']);
    Card.decoded = 0;
    final kept = await created.query
        .where(card.path(r'$.title').equalTo('Kept Garden'))
        .single();
    expect(Card.decoded, 1);
    expect(kept.card.pages, 320);
    kept.card = Card(title: 'Kept Garden', pages: 321);
    expect(await context.saveChanges(), 1);
    expect(kept.revision, 1);
    final stored = await database.query('SELECT card, revision FROM notes');
    expect(
      stored.rows.where((row) => (row[0] as String).contains('321')),
      hasLength(1),
    );
    expect(stored.rows.map((row) => row[1]),
        containsAll([BigInt.one, BigInt.zero]));
    Card.decoded = 0;
    final again =
        await created.query.where(card.path(r'$.pages').equalTo(321)).single();
    expect(Card.decoded, 1);
    expect(again.card.pages, 321);
    expect(again.revision, 1);
  });
}
