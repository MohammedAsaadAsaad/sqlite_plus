import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'input',
      help:
          'One model library. Omit it to scan every public @DbEntity under lib/.',
    )
    ..addMultiOption(
      'class',
      help: 'Class to map; repeat to select multiple models.',
      splitCommas: false,
    )
    ..addOption(
      'output',
      help: 'Generated part path; defaults to <input>.orm.g.dart.',
    )
    ..addFlag(
      'check',
      negatable: false,
      help: 'Check generated output without writing.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);
  ArgResults options;
  try {
    options = parser.parse(arguments);
    if (options['help'] == true) {
      stdout.writeln(
        'Usage: dart run sqlite_plus_generator\n'
        '       dart run sqlite_plus_generator --input lib/models.dart\n'
        '${parser.usage}',
      );
      return;
    }
    if (options.rest.isNotEmpty) {
      throw const FormatException('Positional arguments are unsupported.');
    }
    if (options['input'] == null &&
        (options['output'] != null ||
            (options['class'] as List<String>).isNotEmpty)) {
      throw const FormatException(
        '--output and --class apply to one library. Pass --input, or run '
        'without them to scan lib/.',
      );
    }
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n${parser.usage}');
    exitCode = 64;
    return;
  }
  try {
    final check = options['check'] == true;
    if (options['input'] == null) {
      stdout.writeln('Scanning lib/ for public @DbEntity classes.');
      final generated = await generatePackage(
        Directory.current.path,
        ensurePart: !check,
        report: stdout.writeln,
      );
      final rows = <_Row>[];
      for (final library in generated.libraries) {
        rows.add(await _commit(library, check: check));
      }
      rows.add(await _commit(generated.migrations, check: check));
      _summary('the package', rows);
      return;
    }
    final input = options['input'] as String;
    final classes = options['class'] as List<String>;
    final output = options['output'] as String?;
    stdout.writeln('Reading ${_show(input)}.');
    final existing = currentGeneration(
      input,
      outputPath: output,
      classNames: classes,
    );
    final GenerationResult result;
    if (existing != null) {
      result = existing;
      stdout.writeln(
        'Found ${result.entityNames.join(', ')}. '
        'Already generated. Leaving ${_show(result.outputPath)} unchanged.',
      );
    } else {
      final target = output ?? _defaultOutput(input);
      stdout.writeln('Generating ${_show(target)}.');
      result = await generateLibrary(
        input,
        outputPath: output,
        classNames: classes,
      );
      stdout.writeln('Found ${result.entityNames.join(', ')}.');
    }
    _summary(_show(input), [await _commit(result, check: check)]);
  } on GenerationException catch (error) {
    stderr.writeln(error);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln('Generator I/O error: ${error.message} (${error.path})');
    exitCode = 74;
  }
}

final class _Row {
  _Row(this.action, this.result);

  final _Action action;
  final GenerationResult result;
}

enum _Action { created, updated, unchanged, stale }

Future<_Row> _commit(GenerationResult result, {required bool check}) async {
  final file = File(result.outputPath);
  final existed = file.existsSync();
  final same = existed && await file.readAsString() == result.code;
  final action = same
      ? _Action.unchanged
      : check
      ? _Action.stale
      : existed
      ? _Action.updated
      : _Action.created;
  if (!same && !check) await writeGenerated(result);
  final shown = _show(result.outputPath);
  switch (action) {
    case _Action.created:
      stdout.writeln('Created $shown.');
    case _Action.updated:
      stdout.writeln('Updated $shown.');
    case _Action.stale:
      stderr.writeln('Stale $shown.');
      exitCode = 1;
    case _Action.unchanged:
      if (!result.reused) stdout.writeln('Leaving $shown unchanged.');
  }
  return _Row(action, result);
}

void _summary(String subject, List<_Row> rows) {
  stdout.writeln('');
  stdout.writeln('Summary for $subject');
  for (final row in rows) {
    final names = row.result.entityNames.join(', ');
    stdout.writeln(
      '${_label(row.action)}: ${_show(row.result.outputPath)} ($names)',
    );
  }
}

String _label(_Action action) => switch (action) {
  _Action.created => 'Created',
  _Action.updated => 'Updated',
  _Action.unchanged => 'Unchanged',
  _Action.stale => 'Stale',
};

String _defaultOutput(String input) {
  final absolute = p.absolute(input);
  return p.join(
    p.dirname(absolute),
    '${p.basenameWithoutExtension(absolute)}.orm.g.dart',
  );
}

String _show(String path) => p
    .relative(p.absolute(path), from: Directory.current.path)
    .replaceAll('\\', '/');
