import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test(
    'package scan maps every public DbEntity and creates both tables',
    () async {
      final fixture = await Consumer.create('''
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
part 'models.orm.g.dart';
class Draft { Draft(this.id); int id; }
''');
      addTearDown(fixture.close);
      await File(
        p.join(fixture.directory.path, 'lib', 'book.dart'),
      ).writeAsString('''
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity()
class Book {
  Book({this.id, required this.title});
  final BigInt? id;
  final String title;
}
''');
      await File(
        p.join(fixture.directory.path, 'lib', 'note.dart'),
      ).writeAsString('''
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity()
class Note {
  Note({this.id, required this.body});
  final BigInt? id;
  final String body;
}
''');

      final generated = await generatePackage(fixture.directory.path);
      expect(await writePackage(generated), isTrue);
      expect(
        File(
          p.join(fixture.directory.path, 'lib', 'models.orm.g.dart'),
        ).existsSync(),
        isFalse,
      );
      final book = await File(
        p.join(fixture.directory.path, 'lib', 'book.dart'),
      ).readAsString();
      expect(book, contains("part 'book.orm.g.dart';"));
      expect(await writePackage(generated, check: true), isTrue);
      final again = await generatePackage(fixture.directory.path);
      expect(again.libraries.every((library) => library.reused), isTrue);
      expect(again.migrations.reused, isTrue);
      final check = await Process.run(Consumer.dartExecutable, [
        '--packages=${hostPackageConfig().path}',
        p.join(Directory.current.path, 'bin', 'sqlite_plus_generator.dart'),
        '--check',
      ], workingDirectory: fixture.directory.path);
      expect(check.exitCode, 0, reason: '${check.stdout}\n${check.stderr}');
      expect(check.stdout, contains('Already generated'));
      expect(check.stdout, contains('Summary for the package'));
      expect(check.stdout, contains('Unchanged: lib/book.orm.g.dart (Book)'));
      expect(check.stdout, contains('Unchanged: lib/note.orm.g.dart (Note)'));
      expect(check.stdout, isNot(contains('Generating ')));

      const app = r'''
import 'package:generator_consumer/book.dart' hide generatedModel;
import 'package:generator_consumer/note.dart' hide generatedModel;
import 'package:generator_consumer/sqlite_plus_migrations.g.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final connection = await MutableDatabaseConnection.openMemory();
  final context = DbContext(connection, generatedModel);
  await context.migrations.ensureCreated();
  check((await context.migrations.plan()).isEmpty, 'created schema is stable');
  context.set(BookMapping.instance).add(Book(title: 'kept'));
  context.set(NoteMapping.instance).add(Note(body: 'page'));
  check(await context.saveChanges() == 2, 'saved both rows');
  final tables = await context.connection.query(
    "SELECT name FROM sqlite_schema WHERE type = 'table'",
  );
  final names = tables.rows.map((row) => row[0]).toSet();
  check(names.contains('Book') && names.contains('Note'),
      'migrations created both tables');
  await context.close();
  print('package migrations passed');
}
''';
      final run = await fixture.run(app);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect(normalizeNewlines(run.stdout), 'package migrations passed\n');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('package scan reports a package with no DbEntity classes', () async {
    final fixture = await Consumer.create('''
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
part 'models.orm.g.dart';
class Draft { Draft(this.id); int id; }
''');
    addTearDown(fixture.close);
    expect(
      generatePackage(fixture.directory.path),
      throwsA(
        isA<GenerationException>().having(
          (error) => error.diagnostics.single.code,
          'code',
          'G004',
        ),
      ),
    );
  });
}
