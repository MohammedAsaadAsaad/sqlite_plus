import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/browser_app.dart';
import 'package:sqlite_plus_browser/src/launch_bridge.dart';
import 'package:sqlite_plus_browser/src/linux_files.dart';
import 'package:sqlite_plus_browser/src/session.dart';

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var step = 0; step < 40; step++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}

Future<void> _finish(WidgetTester tester, BrowserSession session) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await session.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a sqlite path is kept and flags are ignored', () {
    expect(
      sqliteLaunchPath([
        '--enable-dart-profiling',
        'notes.txt',
        'file:///tmp/library/my%20books.sqlite',
        'other.db',
      ]),
      '/tmp/library/my books.sqlite',
    );
    expect(sqliteLaunchPath(['--foo', 'readme.txt']), isNull);
    expect(sqliteExtension('Archive.DB3'), isTrue);
    expect(sqliteExtension('.db'), isFalse);
    expect(
      desktopEntry(executable: 'sqlite_plus_browser'),
      File('linux/dev.sqliteplus.sqlite_plus_browser.desktop')
          .readAsStringSync(),
    );
    expect(
      sqliteMimeXml,
      File('linux/sqlite-plus-browser.xml').readAsStringSync(),
    );
    expect(
      desktopExec('/opt/SQLite Browser/sqlite_plus_browser'),
      '"/opt/SQLite Browser/sqlite_plus_browser" %f',
    );
  });

  test('an existing handler list keeps its other types', () {
    const existing = '[Default Applications]\n'
        'text/plain=gedit.desktop\n'
        'application/vnd.sqlite3=other.desktop\n'
        '\n'
        '[Added Associations]\n'
        'text/plain=gedit.desktop\n';
    final claimed = claimSqliteHandlers(existing);
    expect(claimed, contains('text/plain=gedit.desktop'));
    expect(
      claimed,
      contains(
        'application/vnd.sqlite3=dev.sqliteplus.sqlite_plus_browser.desktop',
      ),
    );
    expect(
      claimed,
      contains(
        'application/x-sqlite3=dev.sqliteplus.sqlite_plus_browser.desktop',
      ),
    );
    expect(claimed, isNot(contains('other.desktop')));
    expect(claimed, contains('[Added Associations]'));
  });

  test('the desktop entry becomes the default for sqlite files', () async {
    final root = Directory.systemTemp.createTempSync('sqlite-desktop');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final data = Directory('${root.path}/share');
    final config = Directory('${root.path}/config');
    final program = File('${root.path}/sqlite_plus_browser');
    program.writeAsStringSync('');
    program.statSync();
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['+x', program.path]);
    }
    final database = File('${root.path}/library.db');
    database.writeAsStringSync('SQLite format 3\x00kept');
    final notes = File('${root.path}/notes.txt');
    notes.writeAsStringSync('plain');
    final opened = await openedSqliteArgument([
      '--flag',
      notes.path,
      database.path,
    ]);
    expect(opened.file?.name, 'library.db');
    expect(opened.file?.location, database.absolute.path);
    expect(String.fromCharCodes(opened.file!.bytes), startsWith('SQLite'));

    final icon = File('assets/app_icon.png').readAsBytesSync();
    await installLinuxFileAssociation(
      executable: program.path,
      icon: icon,
      dataHome: data,
      configHome: config,
    );

    final desktop = File('${data.path}/applications/$linuxDesktopFile');
    expect(desktop.readAsStringSync(), contains('Exec=${program.path} %f'));
    expect(desktop.readAsStringSync(), contains('Name=SQLite Browser'));
    final validated = await Process.run('desktop-file-validate', [
      desktop.path,
    ]);
    expect(validated.exitCode, 0, reason: validated.stderr.toString());

    final globs = File('${data.path}/mime/globs2').readAsStringSync();
    for (final extension in sqliteExtensions) {
      expect(globs, contains('application/vnd.sqlite3:*.$extension'));
    }
    final cache =
        File('${data.path}/applications/mimeinfo.cache').readAsStringSync();
    expect(
      cache,
      contains('application/vnd.sqlite3=$linuxDesktopFile;'),
    );
    expect(
      cache,
      contains('application/x-sqlite3=$linuxDesktopFile;'),
    );
    final handlers = File('${config.path}/mimeapps.list').readAsStringSync();
    expect(
      handlers,
      contains(
        'application/vnd.sqlite3=$linuxDesktopFile',
      ),
    );
  });

  testWidgets('a database passed at startup opens in the browser', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = BrowserSession();
    await source.openEmpty();
    await source.run('CREATE TABLE books (title TEXT)');
    await source.run("INSERT INTO books (title) VALUES ('Opened Book')");
    final bytes = source.exportBytes();
    await source.close();

    final session = BrowserSession();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LaunchBridge.channel,
      (call) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LaunchBridge.channel,
        null,
      );
    });
    await tester.pumpWidget(
      BrowserApp(
        session: session,
        launch: OpenedFile(
          name: 'library.db',
          bytes: bytes,
          location: '/tmp/library.db',
        ),
      ),
    );
    await _until(tester, find.byKey(const Key('schema-table-books')));
    await tester.tap(find.byKey(const Key('schema-table-books')));
    await tester.pump();
    await _until(tester, find.text('Opened Book'));
    expect(find.text('library.db'), findsWidgets);
    expect(find.byKey(const Key('home-open')), findsNothing);
    await _finish(tester, session);
  });
}
