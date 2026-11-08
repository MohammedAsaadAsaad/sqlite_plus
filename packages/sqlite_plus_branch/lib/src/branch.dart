part of '../sqlite_plus_branch.dart';

/// Coordinates explicit branch operations on one exclusively loaned main engine.
/// Raw SQL/ORM calls must not interleave manager operations. No source ownership
/// or Reactive/Changes interception is installed.
final class SqlitePlusBranches {
  SqlitePlusBranches(
      {required this.database,
      required this.sourceId,
      this.limits = const BranchLimits()}) {
    limits._validate();
    if (sourceId.isEmpty || sourceId.length > 512) {
      throw ArgumentError('sourceId required (max 512)');
    }
  }
  final MutableSqliteDatabase database;

  /// Application-owned stable identity. Reuse only for the same logical source.
  final String sourceId;
  final BranchLimits limits;
  static final _queues = Expando<Future<void>>();
  static final _poisoned = Expando<bool>();
  static final _zone = Object();

  Future<T> _run<T>(Future<T> Function() action) {
    if (identical(Zone.current[_zone], database)) {
      return Future.error(const BranchException('Reentrant branch operation'));
    }
    final prior = _queues[database] ?? Future<void>.value();
    final result = prior.then((_) => runZoned(() async {
          if (_poisoned[database] == true) {
            throw const BranchException(
                'Source requires close/recovery after uncertain transaction');
          }
          if (database.inTransaction) {
            throw const BranchException('Caller transaction must finish first');
          }
          return action();
        }, zoneValues: {_zone: database}));
    _queues[database] =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<SqliteBranch> create({required String name}) => _run(() async {
        _name(name);
        final image = _image(database, limits);
        final base = await _snapshot(image, limits);
        final random = Random.secure();
        final id = List.generate(24,
                (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
            .join();
        final working = await MutableSqliteDatabase.fromImage(image);
        return SqliteBranch._(this, id, name, image, base, working, false);
      });

  /// Restores a portable explicit checkpoint; never changes main data.
  Future<SqliteBranch> restore(Uint8List archive) {
    final bytes = Uint8List.fromList(archive);
    return _run(() async {
      try {
        if (bytes.length > limits.maxArchiveBytes) {
          throw const BranchException('Archive budget exceeded');
        }
        final envelope = jsonDecode(utf8.decode(bytes)) as Map;
        final payload = envelope['payload'] as String;
        if (_hash(utf8.encode(payload)) != envelope['sha256']) {
          throw const FormatException('Checksum');
        }
        final data = jsonDecode(payload) as Map;
        if (data['format'] != 1 || data['sourceId'] != sourceId) {
          throw const FormatException('Format/source identity');
        }
        final name = data['name'] as String, id = data['id'] as String;
        _name(name);
        if (!RegExp(r'^[0-9a-f]{48}$').hasMatch(id) ||
            data['merged'] is! bool) {
          throw const FormatException('Metadata');
        }
        final baseImage = base64Decode(data['base'] as String);
        final workingImage = base64Decode(data['working'] as String);
        for (final image in [baseImage, workingImage]) {
          if (image.length > limits.maxImageBytes) {
            throw const BranchException('Image budget exceeded');
          }
        }
        final base = await _snapshot(baseImage, limits);
        final workingSnapshot = await _snapshot(workingImage, limits);
        _diff(base, workingSnapshot);
        final working = await MutableSqliteDatabase.fromImage(workingImage);
        return SqliteBranch._(
            this, id, name, baseImage, base, working, data['merged'] as bool);
      } catch (error) {
        if (error is BranchException) rethrow;
        throw BranchException('Invalid branch archive', error);
      }
    });
  }

  static void _name(String name) {
    if (name.trim().isEmpty || name.length > 128) {
      throw ArgumentError('Branch name required (max 128)');
    }
  }

  Future<BranchMergeResult> _merge(
          SqliteBranch branch,
          BranchMergePreview? expected,
          Map<String, BranchResolution> resolutions) =>
      _run(() => branch._run(() async {
            final image = _image(branch.database, limits),
                branchHash = _hash(image);
            final work = await _snapshot(image, limits);
            final changes = _diff(branch._base, work);
            final foreignKeys = (await database.query('PRAGMA foreign_keys'))
                .rows
                .single
                .single;
            var began = false, committing = false;
            Object? operationFailure;
            try {
              // All final relationships are validated before commit. Disabling actions
              // avoids cascades mutating rows outside the reviewed three-way merge plan.
              await database.execute('PRAGMA foreign_keys=OFF');
              began = true;
              await database.execute('BEGIN IMMEDIATE');
              final currentImage = database.exportImage();
              if (currentImage.length > limits.maxImageBytes) {
                throw const BranchException('Image budget exceeded');
              }
              final current = await _snapshot(currentImage, limits);
              final receiptExists = (await database.query(
                      "SELECT name FROM sqlite_schema WHERE type='table' AND name=?",
                      [_receiptTable]))
                  .rows
                  .isNotEmpty;
              if (receiptExists) {
                final receipt = await database.query(
                    'SELECT source_id,branch_hash FROM $_receiptTable WHERE branch_id=?',
                    [branch.id]);
                if (receipt.rows.isNotEmpty) {
                  if (receipt.rows.single[0] != sourceId ||
                      receipt.rows.single[1] != branchHash) {
                    throw const BranchException(
                        'Merged branch identity reused with different contents');
                  }
                  await database.execute('ROLLBACK');
                  began = false;
                  branch._merged = true;
                  return const BranchMergeResult(0, alreadyMerged: true);
                }
              }
              if (branch._merged) {
                throw const BranchException(
                    'Branch was already merged; create a new branch');
              }
              final conflicts = _conflicts(changes, branch._base, current);
              final preview = BranchMergePreview._(branch.id,
                  _hash(currentImage), branchHash, changes, conflicts);
              if (expected != null &&
                  (expected._branchId != branch.id ||
                      expected._mainHash != preview._mainHash ||
                      expected._branchHash != branchHash)) {
                throw const BranchException(
                    'Stale merge preview; review current data again');
              }
              final conflictIds = conflicts.map((c) => c.id).toSet();
              if (resolutions.keys.any((id) => !conflictIds.contains(id))) {
                throw const BranchException('Unknown conflict resolution');
              }
              if (conflicts.any((c) => !resolutions.containsKey(c.id))) {
                throw BranchConflictException(preview);
              }
              final conflictsByChange = <BranchRowDiff, List<BranchConflict>>{};
              for (final conflict in conflicts) {
                (conflictsByChange[conflict.change] ??= []).add(conflict);
              }
              final operations =
                  <(_Table, Map<String, Object?>?, Map<String, Object?>?)>[];
              for (final change in changes) {
                final table = current.tables[change.table]!;
                final row = table.rows[table.identity(change._key)];
                final rowConflicts =
                    conflictsByChange[change] ?? const <BranchConflict>[];
                Map<String, Object?>? desired;
                if (rowConflicts.any((c) => c.column == null)) {
                  final resolution = resolutions[rowConflicts.single.id]!;
                  if (resolution._kind == 'value') {
                    throw const BranchException(
                        'Row conflicts accept useMain/useBranch only');
                  }
                  desired = resolution._kind == 'main' ? row : change._after;
                } else if (change._after == null) {
                  desired = null;
                } else if (change._before == null || row == null) {
                  desired = change._after;
                } else {
                  desired = Map.of(row);
                  for (final column in change.changedColumns) {
                    final found = rowConflicts.where((c) => c.column == column);
                    if (found.isEmpty) {
                      desired[column] = change._after[column];
                    } else {
                      final resolution = resolutions[found.single.id]!;
                      desired[column] = switch (resolution._kind) {
                        'main' => row[column],
                        'branch' => change._after[column],
                        _ => _copyValue(resolution._value),
                      };
                    }
                  }
                }
                if (!_sameRow(row, desired)) {
                  operations.add((table, row, desired));
                }
              }
              for (final op in operations.where((o) => o.$3 == null)) {
                final table = op.$1, row = op.$2!;
                await database.execute(
                    'DELETE FROM ${_quote(table.name)} WHERE ${table.keys.map((k) => '${_quote(k)}=?').join(' AND ')}',
                    table.keys.map((k) => row[k]).toList());
              }
              for (final op in operations.where((o) => o.$3 != null)) {
                final table = op.$1, row = op.$3!;
                if (op.$2 == null) {
                  await database.execute(
                      'INSERT INTO ${_quote(table.name)} (${table.columns.map(_quote).join(',')}) VALUES (${List.filled(table.columns.length, '?').join(',')})',
                      table.columns.map((c) => row[c]).toList());
                } else {
                  final columns = table.columns
                      .where((c) =>
                          !table.keys.contains(c) && !_same(op.$2![c], row[c]))
                      .toList();
                  if (columns.isNotEmpty) {
                    await database.execute(
                        'UPDATE ${_quote(table.name)} SET ${columns.map((c) => '${_quote(c)}=?').join(',')} WHERE ${table.keys.map((k) => '${_quote(k)}=?').join(' AND ')}',
                        [
                          ...columns.map((c) => row[c]),
                          ...table.keys.map((k) => row[k])
                        ]);
                  }
                }
              }
              // SQL conflict policies must not silently ignore or replace rows.
              // Check the complete expected logical state, including untouched rows.
              for (final op in operations) {
                final table = op.$1;
                final row = op.$3;
                final identity = table.identity(op.$2 ?? row!);
                if (row == null) {
                  table.rows.remove(identity);
                } else {
                  table.rows[identity] = row;
                }
              }
              final finalImage = database.exportImage();
              if (finalImage.length > limits.maxImageBytes) {
                throw const BranchException('Merged image budget exceeded');
              }
              final actual = await _snapshot(finalImage, limits);
              for (final table in current.tables.values) {
                final rows = actual.tables[table.name]!.rows;
                if (rows.length != table.rows.length ||
                    table.rows.entries
                        .any((e) => !_sameRow(e.value, rows[e.key]))) {
                  throw const BranchException(
                      'SQL conflict policy changed the reviewed merge result');
                }
              }
              if ((await database.query('PRAGMA foreign_key_check'))
                  .rows
                  .isNotEmpty) {
                throw const BranchException('Merge would violate foreign keys');
              }
              if (!receiptExists) await database.execute(_receiptSql);
              await database.execute('INSERT INTO $_receiptTable VALUES(?,?,?)',
                  [branch.id, sourceId, branchHash]);
              if (_hash(_image(branch.database, limits)) != branchHash) {
                throw const BranchException(
                    'Working branch changed during merge');
              }
              committing = true;
              await database.execute('COMMIT');
              began = false;
              branch._merged = true;
              return BranchMergeResult(operations.length);
            } catch (error, stack) {
              operationFailure = error;
              if (committing) {
                _poisoned[database] = true;
              }
              if (began && database.inTransaction) {
                try {
                  await database.execute('ROLLBACK');
                } catch (cleanup) {
                  _poisoned[database] = true;
                  Error.throwWithStackTrace(
                      operationFailure = BranchException(
                          'Merge and rollback failed',
                          (operation: error, rollback: cleanup)),
                      stack);
                }
              }
              Error.throwWithStackTrace(error, stack);
            } finally {
              try {
                await database.execute(
                    'PRAGMA foreign_keys=${foreignKeys == BigInt.zero ? 'OFF' : 'ON'}');
              } catch (error) {
                _poisoned[database] = true;
                throw BranchException(
                    'Cannot restore foreign-key mode; source requires recovery',
                    (operation: operationFailure, restore: error));
              }
            }
          }));
}

/// One independent in-memory working connection plus immutable base image.
/// Explicit exportArchive checkpoints persist it; writes are not auto-saved.
final class SqliteBranch {
  SqliteBranch._(this._owner, this.id, this.name, this._baseImage, this._base,
      this._database, this._merged);
  final SqlitePlusBranches _owner;
  final String id, name;
  final Uint8List _baseImage;
  final _Snapshot _base;
  final MutableSqliteDatabase _database;
  bool _merged, _closed = false, _busy = false;
  bool get isMerged => _merged;
  MutableSqliteDatabase get database {
    if (_closed) throw const BranchException('Branch closed');
    return _database;
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    if (_closed || _busy) throw const BranchException('Branch closed or busy');
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<List<BranchRowDiff>> diff() =>
      _run(() async => List.unmodifiable(_diff(_base,
          await _snapshot(_image(database, _owner.limits), _owner.limits))));

  Future<BranchMergePreview> previewMerge() => _owner._run(() => _run(() async {
        final work = _image(database, _owner.limits);
        final main = _image(_owner.database, _owner.limits);
        final changes = _diff(_base, await _snapshot(work, _owner.limits));
        final conflicts =
            _conflicts(changes, _base, await _snapshot(main, _owner.limits));
        return BranchMergePreview._(
            id, _hash(main), _hash(work), changes, conflicts);
      }));

  Future<BranchMergeResult> merge(
      {BranchMergePreview? preview,
      Map<String, BranchResolution> resolutions = const {}}) {
    final copy = Map<String, BranchResolution>.of(resolutions);
    return _owner._merge(this, preview, copy);
  }

  Future<Uint8List> exportArchive() => _run(() async {
        final image = _image(database, _owner.limits);
        _diff(_base, await _snapshot(image, _owner.limits));
        final payload = jsonEncode({
          'format': 1,
          'id': id,
          'name': name,
          'sourceId': _owner.sourceId,
          'merged': _merged,
          'base': base64Encode(_baseImage),
          'working': base64Encode(image)
        });
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(
            {'payload': payload, 'sha256': _hash(utf8.encode(payload))})));
        if (bytes.length > _owner.limits.maxArchiveBytes) {
          throw const BranchException('Archive budget exceeded');
        }
        return bytes;
      });

  /// Discards this in-memory handle; never modifies main or external checkpoints.
  Future<void> close() => _run(() async {
        await _database.close();
        _closed = true;
      });
}
