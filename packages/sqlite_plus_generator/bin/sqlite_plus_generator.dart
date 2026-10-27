import 'dart:io';

import 'package:args/args.dart';
import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('input', help: 'Dart model library containing the output part.')
    ..addMultiOption('class',
        help: 'Class to map; repeat to select multiple models.',
        splitCommas: false)
    ..addOption('output',
        help: 'Generated part path; defaults to <input>.orm.g.dart.')
    ..addFlag('check',
        negatable: false, help: 'Check generated output without writing.')
    ..addFlag('help', abbr: 'h', negatable: false);
  ArgResults options;
  try {
    options = parser.parse(arguments);
    if (options['help'] == true) {
      stdout.writeln(
          'Usage: dart run sqlite_plus_generator --input lib/models.dart\n${parser.usage}');
      return;
    }
    if (options.rest.isNotEmpty || options['input'] == null) {
      throw const FormatException(
          '--input is required; positional arguments are unsupported.');
    }
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n${parser.usage}');
    exitCode = 64;
    return;
  }
  try {
    final result = await generateLibrary(options['input'] as String,
        outputPath: options['output'] as String?,
        classNames: options['class'] as List<String>);
    final valid = await writeGenerated(result, check: options['check'] as bool);
    if (!valid) {
      stderr.writeln('Generated output is stale: ${result.outputPath}');
      exitCode = 1;
    } else {
      stdout.writeln('${options['check'] == true ? 'Verified' : 'Generated'} '
          '${result.outputPath} (${result.entityNames.length} models)');
    }
  } on GenerationException catch (error) {
    stderr.writeln(error);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln('Generator I/O error: ${error.message} (${error.path})');
    exitCode = 74;
  }
}
