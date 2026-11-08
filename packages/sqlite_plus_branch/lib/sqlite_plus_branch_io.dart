/// Explicit dart:io checkpoint storage. Import the core entry point on Web.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'sqlite_plus_branch.dart';
export 'sqlite_plus_branch.dart';

/// One branch per path, two alternating checksummed checkpoint slots.
/// A torn newest write falls back to the previous valid checkpoint. Completed
/// writes are flushed, but Dart provides no portable directory fsync guarantee.
/// One owning isolate/process per path; do not delete or replace the lock file.
final class FileBranchStore {
  FileBranchStore._(this.path, this._lock, this._lease, this.maxArchiveBytes);
  final String path, _lease;
  final RandomAccessFile _lock;
  final int maxArchiveBytes;
  bool _busy = false, _closed = false;
  static final _leases = <String>{};

  static Future<FileBranchStore> open(String path,
      {int maxArchiveBytes = 96 * 1024 * 1024 + 16384}) async {
    if (maxArchiveBytes < 1) throw ArgumentError.value(maxArchiveBytes);
    final lockFile = File('$path.lock').absolute;
    final canonical = await lockFile.exists()
        ? await lockFile.resolveSymbolicLinks()
        : '${await lockFile.parent.resolveSymbolicLinks()}${Platform.pathSeparator}${lockFile.path.split(Platform.pathSeparator).last}';
    // Check before opening a second descriptor: closing any descriptor for the
    // same POSIX inode can release this process's advisory locks.
    if (!_leases.add(canonical)) {
      throw const BranchException('Checkpoint path already open');
    }
    RandomAccessFile? lock;
    try {
      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive, 0, 1);
      return FileBranchStore._(
          File(path).absolute.path, lock, canonical, maxArchiveBytes);
    } catch (_) {
      _leases.remove(canonical);
      await lock?.close();
      rethrow;
    }
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    if (_closed || _busy) {
      throw const BranchException('Checkpoint store closed or busy');
    }
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<({int generation, Uint8List? archive})?> _latest() async {
    final valid = <({int generation, Uint8List? archive})>[];
    var found = false;
    for (final slot in [0, 1]) {
      final file = File('$path.$slot');
      if (!await file.exists()) continue;
      found = true;
      try {
        if (await file.length() > maxArchiveBytes * 2 + 4096) {
          throw const FormatException('Slot budget');
        }
        final raw = jsonDecode(await file.readAsString()) as Map;
        final payload = raw['payload'] as String;
        if (sha256.convert(utf8.encode(payload)).toString() != raw['sha256']) {
          throw const FormatException('Slot checksum');
        }
        final data = jsonDecode(payload) as Map;
        final generation = data['generation'] as int;
        if (data['format'] != 1 ||
            generation < 1 ||
            generation > 9007199254740991) {
          throw const FormatException('Slot version');
        }
        final archive = data['archive'] == null
            ? null
            : base64Decode(data['archive'] as String);
        if (archive != null && archive.length > maxArchiveBytes) {
          throw const FormatException('Archive budget');
        }
        valid.add((generation: generation, archive: archive));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    if (valid.isEmpty) {
      if (found) throw const BranchException('No valid checkpoint slot');
      return null;
    }
    valid.sort((a, b) => b.generation.compareTo(a.generation));
    if (valid.length == 2 && valid[0].generation == valid[1].generation) {
      throw const BranchException('Ambiguous checkpoint generations');
    }
    return valid.first;
  }

  Future<Uint8List?> readArchive() => _run(() async {
        final archive = (await _latest())?.archive;
        return archive == null ? null : Uint8List.fromList(archive);
      });

  Future<void> save(SqliteBranch branch) => _run(() async {
        final archive = await branch.exportArchive();
        if (archive.length > maxArchiveBytes) {
          throw const BranchException('Checkpoint budget exceeded');
        }
        await _write(archive);
      });

  /// Writes a tombstone; older checkpoint bytes are not securely erased.
  Future<void> delete() => _run(() => _write(null));

  Future<void> _write(Uint8List? archive) async {
    final generation = ((await _latest())?.generation ?? 0) + 1;
    if (generation > 9007199254740991) {
      throw const BranchException('Checkpoint generation exhausted');
    }
    final payload = jsonEncode({
      'format': 1,
      'generation': generation,
      'archive': archive == null ? null : base64Encode(archive)
    });
    final text = jsonEncode({
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(payload)).toString()
    });
    await File('$path.${generation % 2}').writeAsString(text, flush: true);
  }

  Future<void> close() => _run(() async {
        await _lock.unlock(0, 1);
        await _lock.close();
        _leases.remove(_lease);
        _closed = true;
      });
}
