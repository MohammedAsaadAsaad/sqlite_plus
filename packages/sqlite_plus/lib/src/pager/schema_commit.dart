import 'dart:convert';
import 'dart:typed_data';

import '../storage/durable_storage_backend.dart';
import 'rollback_journal_pager.dart';

/// One durable commit across two or more rollback journals.
///
/// Each schema first syncs a pending redo. The commit point is the sync of
/// this record. Recovery applies every listed redo, or none of them. This
/// file is not an official SQLite master journal.
final class SchemaCommit {
  static const _magic = [0x53, 0x51, 0x43, 0x52, 0x4F, 0x53, 0x01, 0x00];

  static Future<void> commit({
    required DurableStorageBackend journal,
    required List<({String name, RollbackJournalPager pager, Uint8List image})>
        schemas,
  }) async {
    if (schemas.length < 2) {
      throw ArgumentError('A schema commit needs two databases');
    }
    final pagers = <RollbackJournalPager>[];
    final marks = <({String name, int salt, int end})>[];
    try {
      for (final schema in schemas) {
        final mark = await schema.pager.stageImage(schema.image);
        pagers.add(schema.pager);
        marks.add((name: schema.name, salt: mark.salt, end: mark.end));
      }
      await journal.write(0, _encode(marks));
      await journal.sync();
      for (final pager in pagers) {
        await pager.finishStaged();
      }
      await journal.truncate(0);
      await journal.sync();
    } catch (_) {
      for (final pager in pagers) {
        pager.abandonStaged();
      }
      rethrow;
    }
  }

  /// Applies a durable schema commit, or drops pending redos when the record
  /// is absent or torn. Call this before opening the pagers.
  static Future<void> recover({
    required DurableStorageBackend journal,
    required List<
            ({
              String name,
              DurableStorageBackend database,
              DurableStorageBackend redo
            })>
        schemas,
  }) async {
    final committed = await _read(journal);
    for (final schema in schemas) {
      final marks = committed?.where((entry) => entry.name == schema.name);
      final staged = marks == null || marks.isEmpty ? null : marks.first;
      await RollbackJournalPager.recoverStaged(schema.database, schema.redo,
          applySalt: staged?.salt, applyEnd: staged?.end);
    }
    if (await journal.length() != 0) {
      await journal.truncate(0);
      await journal.sync();
    }
  }

  static Uint8List _encode(List<({String name, int salt, int end})> marks) {
    final body = BytesBuilder();
    for (final mark in marks) {
      final name = utf8.encode(mark.name);
      if (name.isEmpty || name.length > 255) {
        throw const FormatException('Invalid schema commit name');
      }
      final fields = ByteData(10);
      fields.setUint16(0, name.length);
      fields.setUint32(2, mark.salt);
      fields.setUint32(6, mark.end);
      body.add(fields.buffer.asUint8List());
      body.add(name);
    }
    final payload = body.toBytes();
    final bytes = Uint8List(16 + payload.length);
    bytes.setRange(0, 8, _magic);
    ByteData.sublistView(bytes).setUint32(8, marks.length);
    bytes.setRange(16, bytes.length, payload);
    ByteData.sublistView(bytes).setUint32(12, _mix(bytes));
    return bytes;
  }

  static Future<List<({String name, int salt, int end})>?> _read(
      DurableStorageBackend journal) async {
    final length = await journal.length();
    if (length == 0) return null;
    if (length < 16 || length > 1024 * 1024) return null;
    final bytes = Uint8List(length);
    var read = 0;
    while (read < length) {
      final count =
          await journal.read(read, Uint8List.sublistView(bytes, read));
      if (count <= 0 || count > length - read) return null;
      read += count;
    }
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    final fields = ByteData.sublistView(bytes);
    final checksum = fields.getUint32(12);
    fields.setUint32(12, 0);
    if (_mix(bytes) != checksum) return null;
    fields.setUint32(12, checksum);
    final count = fields.getUint32(8);
    final marks = <({String name, int salt, int end})>[];
    var cursor = 16;
    for (var i = 0; i < count; i++) {
      if (cursor + 10 > bytes.length) return null;
      final entry = ByteData.sublistView(bytes, cursor);
      final nameLength = entry.getUint16(0);
      final salt = entry.getUint32(2);
      final end = entry.getUint32(6);
      cursor += 10;
      if (nameLength == 0 || cursor + nameLength > bytes.length) return null;
      final name = utf8.decode(bytes.sublist(cursor, cursor + nameLength),
          allowMalformed: false);
      cursor += nameLength;
      marks.add((name: name, salt: salt, end: end));
    }
    if (cursor != bytes.length || marks.isEmpty) return null;
    return marks;
  }

  static int _mix(Uint8List bytes) {
    var sum = 0;
    for (final byte in bytes) {
      sum = (sum + byte + 1) * 131 & 0xffffffff;
    }
    return sum;
  }
}
