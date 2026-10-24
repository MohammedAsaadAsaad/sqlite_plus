import 'dart:typed_data';

import '../btree/database_image_builder.dart';
import 'image_mutations.dart';
import '../pager/image_pager.dart';
import '../storage/memory_storage_backend.dart';
import 'database.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

final class MutationResult {
  const MutationResult(this.changes, this.lastInsertRowid, [this.returning]);
  final QueryResult? returning;
  final int changes;
  final BigInt? lastInsertRowid;
}

/// Serialized image mutations with constraints, secondary indexes and row triggers.
/// In-memory by default; an ImagePager supplies the durable commit boundary.
/// Transactions and savepoints retain independent image snapshots.
final class MutableSqliteDatabase {
  MutableSqliteDatabase._(this._image, this._journal);
  Uint8List _image;
  final ImagePager? _journal;
  bool _busy = false;
  bool _closed = false;
  bool _failed = false;
  bool _foreignKeys = false;
  Uint8List? _transactionStart;
  bool _explicitTransaction = false;
  final List<(String, Uint8List)> _savepoints = [];
  bool get inTransaction => _transactionStart != null;
  static Future<MutableSqliteDatabase> create(
          {int pageSize = 4096, int encoding = 1}) =>
      fromImage(
          DatabaseImageBuilder.empty(pageSize: pageSize, encoding: encoding));
  static Future<MutableSqliteDatabase> fromImage(Uint8List image) async {
    final storage = MemoryStorageBackend();
    await storage.write(0, image);
    final database = await SqliteDatabase.openReadOnly(storage);
    await database.close();
    return MutableSqliteDatabase._(Uint8List.fromList(image), null);
  }

  static Future<MutableSqliteDatabase> fromJournalPager(
          ImagePager pager) async =>
      MutableSqliteDatabase._(await pager.readImage(), pager);
  static Future<MutableSqliteDatabase> fromImagePager(ImagePager pager) =>
      fromJournalPager(pager);
  Uint8List exportImage() {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    return Uint8List.fromList(_image);
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_closed || _failed || _busy) {
      throw StateError('Database closed or busy');
    }
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      _exclusive(() async {
        final pp = SqlParser(sql);
        if (pp.take('PRAGMA') && pp.take('FOREIGN_KEYS')) {
          pp.finish();
          if (parameters.isNotEmpty) {
            throw const SqlException('PRAGMA bindings unsupported');
          }
          return QueryResult([
            'foreign_keys'
          ], [
            [boolean(_foreignKeys)]
          ]);
        }
        final storage = MemoryStorageBackend();
        await storage.write(0, _image);
        final reader = await SqliteDatabase.openReadOnly(storage);
        try {
          return await reader.query(sql, parameters);
        } finally {
          await reader.close();
        }
      });
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      _exclusive(() async {
        final parser = SqlParser(sql);
        if (parser.take('PRAGMA')) {
          final name = asciiLower(parser.identifier());
          if (!['foreign_keys', 'user_version', 'application_id']
              .contains(name)) {
            throw const SqlException('Unsupported writable PRAGMA');
          }
          parser.require('=');
          final expr = parser.expression();
          parser.finish();
          expr.validate({});
          if (parameters.isNotEmpty) {
            throw const SqlException('PRAGMA bindings unsupported');
          }
          final value = expr.evaluate(EvalContext({}, {}, []));
          if (name == 'foreign_keys') {
            if (!inTransaction) _foreignKeys = truth(value) == true;
          } else {
            var number = numeric(value);
            final integer = number is BigInt
                ? number
                : number is double && number.isFinite
                    ? BigInt.from(number)
                    : BigInt.zero;
            final signed = integer >= BigInt.from(-2147483648) &&
                    integer <= BigInt.from(2147483647)
                ? integer.toInt()
                : 0;
            final image = Uint8List.fromList(_image);
            final fields = ByteData.sublistView(image);
            fields.setInt32(name == 'user_version' ? 60 : 68, signed);
            final counter = (fields.getUint32(24) + 1) & 0xffffffff;
            fields.setUint32(24, counter);
            fields.setUint32(92, counter);
            if (_journal != null && !inTransaction) {
              try {
                await _journal.commitImage(image);
              } catch (_) {
                _failed = true;
                rethrow;
              }
            }
            _image = image;
          }
          return const MutationResult(0, null);
        }
        if (['BEGIN', 'COMMIT', 'END', 'ROLLBACK', 'SAVEPOINT', 'RELEASE']
            .contains(parser.current.keyword)) {
          if (parameters.isNotEmpty) {
            throw const SqlException(
                'Transaction statements take no parameters');
          }
          return _transaction(parser);
        }
        final result = await (await ImageMutations.load(_image)).execute(
            sql, parameters,
            foreignKeys: _foreignKeys, inTransaction: inTransaction);
        if (!identical(result.image, _image)) {
          if (_journal != null && !inTransaction) {
            try {
              await _journal.commitImage(result.image);
            } catch (_) {
              _failed = true;
              rethrow;
            }
          }
          _image = result.image;
        }
        return MutationResult(
            result.changes, result.lastRowid, result.returning);
      });

  Future<MutationResult> _transaction(SqlParser parser) async {
    final op = parser.current.keyword;
    parser.position++;
    if (op == 'BEGIN') {
      if (!parser.take('DEFERRED') && !parser.take('IMMEDIATE')) {
        parser.take('EXCLUSIVE');
      }
      parser.take('TRANSACTION');
      parser.finish();
      if (inTransaction) throw const SqlException('Transaction already active');
      _transactionStart = Uint8List.fromList(_image);
      _explicitTransaction = true;
    } else if (op == 'SAVEPOINT') {
      final name = asciiLower(parser.identifier());
      parser.finish();
      _transactionStart ??= Uint8List.fromList(_image);
      _savepoints.add((name, Uint8List.fromList(_image)));
    } else if (op == 'RELEASE') {
      parser.take('SAVEPOINT');
      final name = asciiLower(parser.identifier());
      parser.finish();
      final index = _savepoints.lastIndexWhere((entry) => entry.$1 == name);
      if (index < 0) throw const SqlException('No such savepoint');
      if (index == 0 && !_explicitTransaction) {
        await _commitTransaction();
      } else {
        _savepoints.removeRange(index, _savepoints.length);
      }
    } else if (op == 'ROLLBACK') {
      parser.take('TRANSACTION');
      if (parser.take('TO')) {
        parser.take('SAVEPOINT');
        final name = asciiLower(parser.identifier());
        parser.finish();
        final index = _savepoints.lastIndexWhere((entry) => entry.$1 == name);
        if (index < 0) throw const SqlException('No such savepoint');
        _image = Uint8List.fromList(_savepoints[index].$2);
        _savepoints.removeRange(index + 1, _savepoints.length);
      } else {
        parser.finish();
        if (!inTransaction) throw const SqlException('No active transaction');
        _image = _transactionStart!;
        _clearTransaction();
      }
    } else {
      parser.take('TRANSACTION');
      parser.finish();
      if (!inTransaction) throw const SqlException('No active transaction');
      await _commitTransaction();
    }
    return const MutationResult(0, null);
  }

  void _clearTransaction() {
    _transactionStart = null;
    _explicitTransaction = false;
    _savepoints.clear();
  }

  Future<void> _commitTransaction() async {
    if (_foreignKeys) (await ImageMutations.load(_image)).validateForeignKeys();
    if (_journal != null) {
      try {
        await _journal.commitImage(_image);
      } catch (_) {
        _failed = true;
        rethrow;
      }
    }
    _clearTransaction();
  }

  Future<void> close() async {
    if (_busy) throw StateError('Database operation in progress');
    if (_closed) return;
    if (inTransaction) {
      _image = _transactionStart!;
      _clearTransaction();
    }
    _closed = true;
    await _journal?.close();
  }
}
