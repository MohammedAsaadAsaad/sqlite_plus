import 'dart:io';
import 'dart:typed_data';

import 'launch_bridge.dart';

/// Desktop file installed for this program.
const linuxDesktopFile = 'dev.sqliteplus.sqlite_plus_browser.desktop';

/// Mime package installed for this program.
const linuxMimePackage = 'sqlite-plus-browser.xml';

/// Types a SQLite file uses on Linux.
const sqliteMimeTypes = [
  'application/vnd.sqlite3',
  'application/x-sqlite3',
];

/// Extensions that open in this program.
const sqliteExtensions = ['db', 'sqlite', 'sqlite3', 'db3'];

const _header = 'SQLite format 3';

/// The first database path in [args], ignoring flags and other files.
String? sqliteLaunchPath(List<String> args) {
  for (final arg in args) {
    final path = _localPath(arg);
    if (path != null && sqliteExtension(path)) return path;
  }
  return null;
}

/// True when [path] ends with a SQLite extension.
bool sqliteExtension(String path) {
  final name = _baseName(path).toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return false;
  return sqliteExtensions.contains(name.substring(dot + 1));
}

/// Reads the first SQLite file named by [args].
Future<LinuxOpen> openedSqliteArgument(List<String> args) async {
  for (final arg in args) {
    final path = _localPath(arg);
    if (path == null) continue;
    final file = File(path);
    FileStat stat;
    try {
      stat = file.statSync();
    } on FileSystemException {
      continue;
    }
    if (stat.type != FileSystemEntityType.file) continue;
    final named = sqliteExtension(path);
    if (!named && !await _sqliteHeader(file)) continue;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        return LinuxOpen.message('The file is empty.');
      }
      return LinuxOpen.file(
        OpenedFile(
          name: _baseName(file.absolute.path),
          bytes: bytes,
          location: file.absolute.path,
        ),
      );
    } on FileSystemException catch (error) {
      return LinuxOpen.message(error.message);
    }
  }
  return const LinuxOpen.none();
}

/// A command-line open, or a reason it could not be read.
class LinuxOpen {
  const LinuxOpen.file(this.file) : message = null;

  const LinuxOpen.message(this.message) : file = null;

  const LinuxOpen.none()
      : file = null,
        message = null;

  final OpenedFile? file;
  final String? message;
}

/// Desktop entry whose Exec field launches [executable].
String desktopEntry({required String executable, bool tryExec = false}) {
  final program = desktopExec(executable);
  final probe = tryExec ? 'TryExec=${desktopToken(executable)}\n' : '';
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=SQLite Browser\n'
      'GenericName=Database Browser\n'
      'Comment=Open a SQLite database\n'
      'Exec=$program\n'
      '$probe'
      'Icon=dev.sqliteplus.sqlite_plus_browser\n'
      'Terminal=false\n'
      'Categories=Development;Database;\n'
      'MimeType=application/vnd.sqlite3;application/x-sqlite3;\n'
      'StartupWMClass=dev.sqliteplus.sqlite_plus_browser\n';
}

/// Quotes [executable] when the desktop spec reserves a character in it.
String desktopExec(String executable) => '${desktopToken(executable)} %f';

/// One desktop-file token for [value].
String desktopToken(String value) {
  final reserved = RegExp('[\\s"\'\\\\<>~|&;\$*?#()`]');
  if (!reserved.hasMatch(value)) return value;
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

/// Shared MIME info that attaches the SQLite extensions.
const sqliteMimeXml = '''<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/vnd.sqlite3">
    <comment>SQLite database</comment>
    <glob pattern="*.db"/>
    <glob pattern="*.db3"/>
    <glob pattern="*.sqlite"/>
    <glob pattern="*.sqlite3"/>
    <magic priority="50">
      <match type="string" value="SQLite format 3" offset="0"/>
    </magic>
    <alias type="application/x-sqlite3"/>
  </mime-type>
</mime-info>
''';

/// Puts this program in the user's desktop and MIME databases.
Future<void> installLinuxFileAssociation({
  required String executable,
  required Uint8List icon,
  Directory? dataHome,
  Directory? configHome,
}) async {
  final data = dataHome ?? Directory(_dataHome());
  final config = configHome ?? Directory(_configHome());
  final applications = Directory('${data.path}/applications');
  final mime = Directory('${data.path}/mime/packages');
  final icons = Directory('${data.path}/icons/hicolor/512x512/apps');
  applications.createSync(recursive: true);
  mime.createSync(recursive: true);
  icons.createSync(recursive: true);
  File('${applications.path}/$linuxDesktopFile').writeAsStringSync(
    desktopEntry(executable: executable, tryExec: true),
  );
  File('${mime.path}/$linuxMimePackage').writeAsStringSync(sqliteMimeXml);
  File('${icons.path}/dev.sqliteplus.sqlite_plus_browser.png')
      .writeAsBytesSync(icon);
  await _tool('update-desktop-database', [applications.path]);
  await _tool('update-mime-database', ['${data.path}/mime']);
  _claimDefaults(config);
}

/// Adds this program as the default handler without dropping other types.
String claimSqliteHandlers(String existing) {
  const desktop = linuxDesktopFile;
  final lines = existing.replaceAll('\r\n', '\n').split('\n');
  final out = <String>[];
  var inDefaults = false;
  var sawDefaults = false;
  final seen = <String>{};

  void finishDefaults() {
    for (final type in sqliteMimeTypes) {
      if (!seen.contains(type)) out.add('$type=$desktop');
    }
    seen.clear();
  }

  for (final line in lines) {
    final trimmed = line.trim();
    final section = trimmed.startsWith('[') && trimmed.endsWith(']');
    if (section) {
      if (inDefaults) finishDefaults();
      inDefaults = trimmed == '[Default Applications]';
      if (inDefaults) sawDefaults = true;
      out.add(line);
      continue;
    }
    if (inDefaults && trimmed.contains('=')) {
      final key = trimmed.split('=').first.trim();
      if (sqliteMimeTypes.contains(key)) {
        if (!seen.contains(key)) {
          out.add('$key=$desktop');
          seen.add(key);
        }
        continue;
      }
    }
    out.add(line);
  }
  if (inDefaults) finishDefaults();
  if (!sawDefaults) {
    if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
    out.add('[Default Applications]');
    for (final type in sqliteMimeTypes) {
      out.add('$type=$desktop');
    }
  }
  final text = out.join('\n');
  return text.endsWith('\n') ? text : '$text\n';
}

String? _localPath(String arg) {
  if (arg.isEmpty || arg.startsWith('-')) return null;
  if (arg.startsWith('file:')) {
    final uri = Uri.tryParse(arg);
    if (uri == null || uri.scheme != 'file') return null;
    return uri.toFilePath();
  }
  return arg;
}

String _baseName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.last;
}

Future<bool> _sqliteHeader(File file) async {
  final handle = await file.open();
  try {
    final bytes = await handle.read(16);
    if (bytes.length < _header.length) return false;
    return String.fromCharCodes(bytes).startsWith(_header);
  } on FileSystemException {
    return false;
  } finally {
    await handle.close();
  }
}

String _dataHome() {
  final set = Platform.environment['XDG_DATA_HOME'];
  if (set != null && set.isNotEmpty) return set;
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  return '$home/.local/share';
}

String _configHome() {
  final set = Platform.environment['XDG_CONFIG_HOME'];
  if (set != null && set.isNotEmpty) return set;
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  return '$home/.config';
}

void _claimDefaults(Directory config) {
  config.createSync(recursive: true);
  final file = File('${config.path}/mimeapps.list');
  final existing = file.existsSync() ? file.readAsStringSync() : '';
  file.writeAsStringSync(claimSqliteHandlers(existing));
}

Future<void> _tool(String name, List<String> args) async {
  try {
    await Process.run(name, args);
  } on ProcessException {
    // The files are already in the user directories.
  }
}
