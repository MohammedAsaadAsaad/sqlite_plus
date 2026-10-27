import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class Consumer {
  Consumer._(this.directory);

  final Directory directory;
  String get input => p.join(directory.path, 'lib', 'models.dart');
  String get output => p.join(directory.path, 'lib', 'models.orm.g.dart');
  String get packageConfig =>
      p.join(directory.path, '.dart_tool', 'package_config.json');
  static String get dartExecutable {
    final sibling = p.join(p.dirname(Platform.resolvedExecutable), 'dart');
    return File(sibling).existsSync() ? sibling : Platform.resolvedExecutable;
  }

  static Future<Consumer> create(String source) async {
    final directory = await Directory.systemTemp.createTemp('sqlite-plus-gen-');
    await Directory(p.join(directory.path, 'lib')).create();
    await Directory(p.join(directory.path, 'bin')).create();
    await Directory(p.join(directory.path, '.dart_tool')).create();
    final configFile = hostPackageConfig();
    final config = jsonDecode(await configFile.readAsString()) as Map;
    final packages = (config['packages'] as List).map((raw) {
      final item = Map<String, Object?>.from(raw as Map);
      item['rootUri'] =
          configFile.uri.resolve(item['rootUri'] as String).toString();
      return item;
    }).toList();
    packages.add({
      'name': 'generator_consumer',
      'rootUri': directory.uri.toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.3',
    });
    await File(p.join(directory.path, '.dart_tool', 'package_config.json'))
        .writeAsString(jsonEncode({'configVersion': 2, 'packages': packages}));
    await File(p.join(directory.path, 'pubspec.yaml')).writeAsString('''
name: generator_consumer
environment:
  sdk: '>=3.3.0 <4.0.0'
''');
    final consumer = Consumer._(directory);
    await File(consumer.input).writeAsString(source);
    return consumer;
  }

  Future<ProcessResult> run(String source) async {
    final main = File(p.join(directory.path, 'bin', 'main.dart'));
    await main.writeAsString(source);
    return Process.run(dartExecutable, ['--packages=$packageConfig', main.path],
        workingDirectory: directory.path);
  }

  Future<ProcessResult> analyze() => Process.run(
      dartExecutable, ['--suppress-analytics', 'analyze', '--fatal-infos'],
      workingDirectory: directory.path);

  Future<ProcessResult> cli(List<String> arguments) =>
      Process.run(dartExecutable, [
        '--packages=${hostPackageConfig().path}',
        File('bin/sqlite_plus_generator.dart').absolute.path,
        ...arguments
      ]);

  Future<void> close() => directory.delete(recursive: true);
}

/// Workspace `pub get` writes this file at the workspace root. A package
/// directory no longer has its own copy.
File hostPackageConfig() {
  var directory = Directory.current.absolute;
  while (true) {
    final candidate =
        File(p.join(directory.path, '.dart_tool', 'package_config.json'));
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
          'No .dart_tool/package_config.json above ${Directory.current.path}');
    }
    directory = parent;
  }
}

String modelSource(String body,
        {String import =
            "import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';"}) =>
    "$import\npart 'models.orm.g.dart';\n$body";

/// Windows checkouts and `Process.run` can use CR LF. Comparisons use LF.
String normalizeNewlines(String value) =>
    value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
