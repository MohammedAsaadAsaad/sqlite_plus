import 'dart:io';

import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('compiled consumer saves, searches, and reads through the ORM only',
      () async {
    final fixture =
        await Consumer.create(await File('example/models.dart').readAsString());
    addTearDown(fixture.close);
    await writeGenerated(await generateLibrary(fixture.input));
    const app = r'''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final connection = await MutableDatabaseConnection.openMemory();
  final context = DbContext(connection, generatedModel);
  await context.migrations.ensureCreated();
  check((await context.migrations.plan()).isEmpty, 'created schema is stable');
  final notes = context.set(NoteMapping.instance);
  final articles = context.set(ArticleMapping.instance);
  final places = context.set(PlaceMapping.instance);
  notes.add(Note(document: '{"title":"kept"}'));
  notes.add(Note(document: '{"title":"other"}'));
  articles.add(Article(body: 'alpha kept'));
  articles.add(Article(body: 'other words'));
  places.add(Place(id: BigInt.one, minX: 0, maxX: 1, minY: 0, maxY: 1));
  places.add(Place(id: BigInt.two, minX: 5, maxX: 6, minY: 5, maxY: 6));
  check(await context.saveChanges() == 6, 'saved six rows');
  final note = (await NoteQuery(notes.query)
          .filter((row) => row.path(r'$.title').equalTo('kept'))
          .toList())
      .single;
  final article =
      (await ArticleQuery(articles.query).search('kept').toList()).single;
  final place = (await PlaceQuery(places.query)
          .filter((row) => row.bounds.intersects(
              const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
          .toList())
      .single;
  check(note.document == '{"title":"kept"}', 'json read');
  check(article.body == 'alpha kept' && article.rowid != null, 'fts read');
  check(place.id == BigInt.one && place.minX == 0 && place.maxX == 1,
      'rtree read');
  check((await context.migrations.plan()).isEmpty, 'schema stayed stable');
  await context.close();
  print('search helpers passed');
}
''';
    expect(app.contains('package:sqlite_plus/'), isFalse);
    expect(app.contains('SELECT'), isFalse);
    expect(app.contains('INSERT'), isFalse);
    expect(app.contains('CREATE'), isFalse);
    expect(app.contains('MATCH'), isFalse);
    final run = await fixture.run(app);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(normalizeNewlines(run.stdout), 'search helpers passed\n');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
