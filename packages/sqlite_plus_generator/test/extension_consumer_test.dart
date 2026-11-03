import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test(
    'generated arabic search and vec0 nearest run through the ORM',
    () async {
      final fixture = await Consumer.create(
        modelSource(
          '''
@DbEntity(module: DbModules.fts5, tokenizer: ArabicTokenizers.arabic)
class Note {
  Note({this.rowid, required this.body});
  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}

@DbEntity(module: DbModules.vec0)
class Point {
  Point({this.rowid, required this.embedding});
  @DbKey(generated: true)
  final BigInt? rowid;
  @DbVector(2)
  final List<double> embedding;
}
''',
          import: """
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
""",
        ),
      );
      addTearDown(fixture.close);
      final generated = await generateLibrary(fixture.input);
      expect(generated.code, contains('tokenizer: "arabic"'));
      expect(generated.code, contains('virtualModule: "vec0"'));
      expect(generated.code, contains('Codecs.vector(2)'));
      expect(generated.code, contains('vectorMetric: "l2"'));
      expect(
        generated.code,
        contains('nearest(List<double> vector, {int k = 10})'),
      );
      await writeGenerated(generated);
      const app = r'''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final connection = await MutableDatabaseConnection.openMemory();
  SqlitePlusArabic.register(connection.database);
  SqlitePlusVec.register(connection.database);
  final context = DbContext(connection, generatedModel);
  await context.migrations.ensureCreated();
  check((await context.migrations.plan()).isEmpty, 'created schema is stable');
  final notes = context.set(NoteMapping.instance);
  final points = context.set(PointMapping.instance);
  notes.add(Note(body: 'في الحديقة'));
  notes.add(Note(body: 'سيارة'));
  points.add(Point(embedding: const [1, 0]));
  points.add(Point(embedding: const [0, 1]));
  check(await context.saveChanges() == 4, 'saved four rows');
  final note = (await NoteQuery(notes.query).search('الحديقة').toList()).single;
  final point = (await PointQuery(points.query)
          .nearest(const [0.9, 0.1], k: 1)
          .toList())
      .single;
  check(note.body == 'في الحديقة', 'arabic search');
  check(point.embedding[0] > 0.5, 'nearest neighbor');
  check((await context.migrations.plan()).isEmpty, 'schema stayed stable');
  await context.close();
  print('extension helpers passed');
}
''';
      expect(app.contains('SELECT'), isFalse);
      expect(app.contains('INSERT'), isFalse);
      expect(app.contains('CREATE'), isFalse);
      expect(app.contains('MATCH'), isFalse);
      final run = await fixture.run(app);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect(normalizeNewlines(run.stdout), 'extension helpers passed\n');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
