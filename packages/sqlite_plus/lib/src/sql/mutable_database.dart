import 'dart:typed_data';

import '../btree/database_image_builder.dart';
import 'image_mutations.dart';
import '../pager/image_pager.dart';
import '../storage/memory_storage_backend.dart';
import 'database.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'function_registry.dart';

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
  bool _recursiveTriggers = false;
  final functions = SqlFunctionRegistry();
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
      return await functions.run(operation);
    } finally {
      _busy = false;
    }
  }

  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      _exclusive(() async {
        final pp = SqlParser(sql);
        final pragmaName =
            pp.take('PRAGMA') ? asciiLower(pp.qualifiedIdentifier()) : null;
        if (['foreign_keys', 'recursive_triggers'].contains(pragmaName)) {
          final name = pragmaName!;
          pp.finish();
          if (parameters.isNotEmpty) {
            throw const SqlException('PRAGMA bindings unsupported');
          }
          return QueryResult([
            name
          ], [
            [
              boolean(
                  name == 'foreign_keys' ? _foreignKeys : _recursiveTriggers)
            ]
          ]);
        }
        final storage = MemoryStorageBackend();
        await storage.write(0, _image);
        final reader =
            await SqliteDatabase.openReadOnly(storage, functions: functions);
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
          final name = asciiLower(parser.qualifiedIdentifier());
          if (![
            'foreign_keys',
            'recursive_triggers',
            'user_version',
            'application_id'
          ].contains(name)) {
            throw const SqlException('Unsupported writable PRAGMA');
          }
          final statePragma =
              ['foreign_keys', 'recursive_triggers'].contains(name);
          final value = _pragmaValue(parser,
              onParsed: statePragma
                  ? (value) {
                      if (name == 'recursive_triggers') {
                        _recursiveTriggers = _pragmaBoolean(value);
                      } else if (!inTransaction) {
                        _foreignKeys = _pragmaBoolean(value);
                      }
                    }
                  : null);
          if (parameters.isNotEmpty) {
            throw const SqlException('PRAGMA bindings unsupported');
          }
          if (!statePragma) {
            final signed = _pragmaInteger(value);
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
        final MutationImage result;
        try {
          result = await (await ImageMutations.load(_image)).execute(
              sql, parameters,
              foreignKeys: _foreignKeys,
              inTransaction: inTransaction,
              recursiveTriggers: _recursiveTriggers);
        } on MutationFailure catch (failure) {
          if (failure.rollbackTransaction) {
            if (inTransaction) {
              _image = _transactionStart!;
              _clearTransaction();
            }
          } else if (failure.partialImage != null) {
            if (_journal != null && !inTransaction) {
              try {
                await _journal.commitImage(failure.partialImage!);
              } catch (_) {
                _failed = true;
                rethrow;
              }
            }
            _image = failure.partialImage!;
          }
          throw failure.error;
        }
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

  String _pragmaValue(SqlParser parser, {void Function(String)? onParsed}) {
    final parenthesized = parser.take('(');
    if (!parenthesized) parser.require('=');
    final negative = parser.take('-');
    final signed = negative || parser.take('+');
    final token = parser.current;
    if (![SqlTokenKind.identifier, SqlTokenKind.string, SqlTokenKind.number]
            .contains(token.kind) ||
        token.keyword == 'NULL' ||
        signed && token.kind != SqlTokenKind.number) {
      throw const SqlException('Invalid PRAGMA value');
    }
    parser.position++;
    if (parenthesized) parser.require(')');
    final value = negative ? '-${token.text}' : token.text;
    // SQLite applies connection-state PRAGMAs during preparation, even if
    // trailing SQL later fails. Header writes wait until preparation succeeds.
    onParsed?.call(value);
    parser.finish();
    return value;
  }

  int _pragmaInteger(String value) {
    final match =
        RegExp(r'^([+-]?)(0[xX][0-9a-fA-F]+|[0-9]+)').firstMatch(value);
    if (match == null) return 0;
    final digits = match[2]!;
    final hexadecimal = digits.startsWith('0x') || digits.startsWith('0X');
    final significant = (hexadecimal ? digits.substring(2) : digits)
        .replaceFirst(RegExp(r'^0+'), '');
    if (significant.isEmpty) return 0;
    if (significant.length > (hexadecimal ? 8 : 10)) return 0;
    var number = BigInt.parse(significant, radix: hexadecimal ? 16 : 10);
    if (hexadecimal && number > BigInt.from(2147483647)) return 0;
    if (match[1] == '-') number = -number;
    return number >= BigInt.from(-2147483648) &&
            number <= BigInt.from(2147483647)
        ? number.toInt()
        : 0;
  }

  bool _pragmaBoolean(String value) {
    if (value.isNotEmpty &&
        value.codeUnitAt(0) >= 48 &&
        value.codeUnitAt(0) <= 57) {
      return _pragmaInteger(value) != 0;
    }
    return ['on', 'yes', 'true'].contains(asciiLower(value));
  }

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
