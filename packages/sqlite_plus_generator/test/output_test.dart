@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Future<Consumer> fixture({String part = 'models.orm.g.dart'}) async {
    final consumer = await Consumer.create('''
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
part '$part';
class Customer { Customer(this.id); int id; }
''');
    addTearDown(consumer.close);
    return consumer;
  }

  test(
    'check never creates custom output directories, then CLI writes atomically',
    () async {
      final consumer = await fixture(part: 'generated/metadata.dart');
      final output = p.join(
        p.dirname(consumer.input),
        'generated',
        'metadata.dart',
      );
      final result = await generateLibrary(consumer.input, outputPath: output);
      expect(await writeGenerated(result, check: true), isFalse);
      expect(Directory(p.dirname(output)).existsSync(), isFalse);
      final cli = await consumer.cli([
        '--input',
        consumer.input,
        '--output',
        output,
        '--class',
        'Customer',
      ]);
      expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
      expect(await File(output).readAsString(), result.code);
      expect(
        Directory(
          p.dirname(output),
        ).listSync().map((entry) => p.basename(entry.path)),
        ['metadata.dart'],
      );
      expect(await writeGenerated(result, check: true), isTrue);
      final analyzed = await consumer.analyze();
      expect(
        analyzed.exitCode,
        0,
        reason: '${analyzed.stdout}\n${analyzed.stderr}',
      );
    },
  );

  test(
    'generation repairs owned part headers after input rename or damage',
    () async {
      final consumer = await fixture();
      await writeGenerated(await generateLibrary(consumer.input));
      final renamed = p.join(p.dirname(consumer.input), 'renamed.dart');
      await File(consumer.input).rename(renamed);
      final repaired = await generateLibrary(
        renamed,
        outputPath: consumer.output,
      );
      expect(repaired.code, contains('part of "renamed.dart";'));
      await writeGenerated(repaired);
      final header = repaired.code.substring(
        0,
        repaired.code.indexOf('part of'),
      );
      for (final broken in [header, '${header}part of legacyName;\n']) {
        await File(consumer.output).writeAsString(broken);
        final next = await generateLibrary(
          renamed,
          outputPath: consumer.output,
        );
        expect(next.code, repaired.code);
        await writeGenerated(next);
      }
    },
  );

  test(
    'write rechecks ownership and rejects binary files and directories',
    () async {
      final consumer = await fixture();
      final result = await generateLibrary(consumer.input);
      await File(consumer.output).writeAsString('// handwritten\n');
      await expectLater(
        writeGenerated(result),
        throwsA(isA<GenerationException>()),
      );
      expect(await File(consumer.output).readAsString(), '// handwritten\n');
      await File(consumer.output).writeAsBytes([0xff, 0xfe, 0x00]);
      await expectLater(
        generateLibrary(consumer.input),
        throwsA(
          isA<GenerationException>().having(
            (error) => error.diagnostics.single.code,
            'ownership diagnostic',
            'G020',
          ),
        ),
      );
      await File(consumer.output).delete();
      await Directory(consumer.output).create();
      await expectLater(
        generateLibrary(consumer.input),
        throwsA(isA<GenerationException>()),
      );
    },
  );

  test(
    'CLI rejects unknown options and unselected classes without output',
    () async {
      final consumer = await fixture();
      expect((await consumer.cli(['--unknown'])).exitCode, 64);
      expect(
        (await consumer.cli([
          '--input',
          consumer.input,
          '--class',
          'Missing',
        ])).exitCode,
        65,
      );
      expect(File(consumer.output).existsSync(), isFalse);
    },
  );
}
