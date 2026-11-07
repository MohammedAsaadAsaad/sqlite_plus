part of 'changes.dart';

extension ChangeTracking on SqlitePlusChanges {
  Future<List<ChangeSource>> sources() => _run(() async {
        await _state();
        await _verifySources();
        return List.unmodifiable([
          for (final source in await _sources(enabledOnly: true))
            ChangeSource(source.name, source.keys, source.columns)
        ]);
      });

  Future<void> _requireRecursiveTriggers() async {
    final value = await database.query('PRAGMA recursive_triggers');
    if (value.rows.single.single != BigInt.one) {
      throw StateError(
          'Tracked writes require PRAGMA recursive_triggers=ON; enable it explicitly on each writer connection');
    }
  }

  Future<List<_Source>> _sources({bool enabledOnly = false}) async {
    final rows = await database.query(
        'SELECT id,name,keys_json,columns_json,schema_sql,triggers_json,enabled FROM _spc_sources');
    final result = <_Source>[];
    for (final row in rows.rows) {
      try {
        final enabled = _integer(row[6]);
        if (enabled != BigInt.zero && enabled != BigInt.one) {
          throw const FormatException();
        }
        if (enabledOnly && enabled == BigInt.zero) continue;
        final keys = (jsonDecode(row[2] as String) as List).cast<String>();
        final columns = (jsonDecode(row[3] as String) as List).cast<String>();
        final triggers =
            (jsonDecode(row[5] as String) as Map).cast<String, String>();
        if (keys.isEmpty ||
            keys.toSet().length != keys.length ||
            columns.toSet().length != columns.length ||
            !keys.every(columns.contains) ||
            triggers.length != 6 ||
            _integer(row[0]) < BigInt.one) {
          throw const FormatException();
        }
        result.add(_Source(_integer(row[0]), row[1] as String, keys, columns,
            row[4] as String, triggers));
      } on FormatException {
        throw const ChangeLogCorrupt('Malformed tracked source');
      } on TypeError {
        throw const ChangeLogCorrupt('Malformed tracked source');
      }
    }
    return result;
  }

  Future<void> _verifySources() async {
    final sources = await _sources(enabledOnly: true);
    if (sources.isEmpty) return;
    final schema =
        await database.query('SELECT type,name,sql FROM sqlite_schema');
    final tables = <String, String>{}, triggers = <String, String>{};
    for (final row in schema.rows) {
      if (row[0] == 'table' && row[1] is String && row[2] is String) {
        tables[row[1] as String] = row[2] as String;
      }
      if (row[0] == 'trigger' && row[1] is String && row[2] is String) {
        final sql = row[2] as String;
        triggers[row[1] as String] = sql;
        final tokens = SqlTokenizer.tokenize(sql);
        for (var i = 0; i + 2 < tokens.length; i++) {
          if (tokens[i].kind == SqlTokenKind.identifier &&
              tokens[i].text.toUpperCase() == 'RAISE' &&
              tokens[i + 1].text == '(' &&
              {'FAIL', 'IGNORE'}.contains(tokens[i + 2].keyword)) {
            throw StateError(
                'Changes does not support RAISE(FAIL) or RAISE(IGNORE) triggers; they may retain unlogged row effects');
          }
        }
      }
    }
    for (final source in sources) {
      if (tables[source.name] != source.schema ||
          source.triggers.entries.any((e) => triggers[e.key] != e.value)) {
        throw StateError(
            'Tracked schema or triggers changed: ${source.name}; explicitly untrack before migrating');
      }
    }
  }

  String _keySql(String scope, List<String> keys) =>
      'json_array(${keys.map((key) => "json_array(${_literal(key)},typeof($scope.${_quote(key)}),CAST($scope.${_quote(key)} AS TEXT))").join(',')})';
  String _changed(String column) =>
      '(typeof(OLD.${_quote(column)})<>typeof(NEW.${_quote(column)}) OR OLD.${_quote(column)} COLLATE BINARY IS NOT NEW.${_quote(column)} COLLATE BINARY)';

  /// Future writes to this ordinary main-schema table must use [transaction].
  /// Primary keys must contain only non-null integers/text, including new keys.
  Future<void> track(
          {required String table,
          List<String>? primaryKey,
          List<String>? columns}) =>
      _run(() async {
        if (table.isEmpty ||
            table.contains('\u0000') ||
            table.toLowerCase().startsWith('_spc_') ||
            table.toLowerCase().startsWith('sqlite_')) {
          throw ArgumentError('Invalid or reserved tracked table');
        }
        final state = await _state();
        await _verifySources();
        await _requireRecursiveTriggers();
        final existing = await _sources(enabledOnly: true);
        if (existing.any((source) => source.name == table)) {
          throw StateError(
              'Table is already tracked; untrack explicitly to change its definition');
        }
        final definition = await database.query(
            "SELECT sql FROM sqlite_schema WHERE type='table' AND name=?",
            [table]);
        if (definition.rows.length != 1 ||
            definition.rows.single.single is! String ||
            (definition.rows.single.single as String)
                .toUpperCase()
                .contains('VIRTUAL TABLE')) {
          throw ArgumentError('Track an ordinary main-schema table');
        }
        final schema = definition.rows.single.single as String;
        final info =
            await database.query('PRAGMA table_info(${_quote(table)})');
        final declared = info.rows
            .where((row) => _integer(row[5]) > BigInt.zero)
            .toList()
          ..sort((a, b) => _integer(a[5]).compareTo(_integer(b[5])));
        final declaredKeys = declared.map((r) => r[1] as String).toList();
        final keys = List<String>.of(primaryKey ?? declaredKeys);
        if (keys.isEmpty ||
            keys.toSet().length != keys.length ||
            keys.length != declaredKeys.length ||
            !keys.every(declaredKeys.contains)) {
          throw ArgumentError('Supply the complete declared primary key');
        }
        final names = info.rows.map((r) => r[1] as String).toSet();
        final requested = columns ?? names.toList();
        if (requested.toSet().length != requested.length ||
            !requested.every(names.contains)) {
          throw ArgumentError('Unknown or duplicate tracked columns');
        }
        final monitored = <String>{...keys, ...requested}.toList();
        final invalid = await database.query(
            'SELECT ${keys.map(_quote).join(',')} FROM ${_quote(table)} WHERE ${keys.map((key) => "typeof(${_quote(key)}) NOT IN ('integer','text')").join(' OR ')} LIMIT 1');
        if (invalid.rows.isNotEmpty) {
          throw ArgumentError(
              'Existing primary keys must be non-null integers/text');
        }
        await _atomic(() async {
          await database.execute(
              'INSERT INTO _spc_sources(name,keys_json,columns_json,schema_sql,triggers_json,enabled) VALUES(?,?,?,?,?,1)',
              [table, jsonEncode(keys), jsonEncode(monitored), schema, '{}']);
          final id = _integer(
              (await database.query('SELECT max(id) FROM _spc_sources'))
                  .rows
                  .single
                  .single);
          final prefix = '_spc_${id}_';
          final statements = <String, String>{};
          for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
            final name = '$prefix${operation.toLowerCase()}_guard';
            final keyCheck = operation == 'DELETE'
                ? ''
                : ' WHEN ${keys.map((key) => "typeof(NEW.${_quote(key)}) NOT IN ('integer','text')").join(' OR ')} THEN RAISE(ABORT,\'Invalid tracked primary key\')';
            statements[name] =
                'CREATE TRIGGER ${_quote(name)} BEFORE $operation ON ${_quote(table)} BEGIN SELECT CASE WHEN (SELECT active_batch FROM _spc_state WHERE id=1) IS NULL THEN RAISE(ABORT,\'Tracked writes require SqlitePlusChanges.transaction\')$keyCheck END; END';
            final event = '$prefix${operation.toLowerCase()}_event';
            final when = operation == 'UPDATE'
                ? ' WHEN ${monitored.map(_changed).join(' OR ')}'
                : '';
            final oldKey =
                operation == 'INSERT' ? 'NULL' : _keySql('OLD', keys);
            final newKey =
                operation == 'DELETE' ? 'NULL' : _keySql('NEW', keys);
            final changed = operation == 'UPDATE'
                ? 'json_array(${monitored.map((column) => 'CASE WHEN ${_changed(column)} THEN ${_literal(column)} END').join(',')})'
                : 'json_array(${monitored.map(_literal).join(',')})';
            statements[event] =
                'CREATE TRIGGER ${_quote(event)} AFTER $operation ON ${_quote(table)}$when BEGIN INSERT INTO _spc_events(batch_id,source_id,kind,old_key,new_key,columns_json) VALUES((SELECT active_batch FROM _spc_state WHERE id=1),$id,${_literal(operation.toLowerCase())},$oldKey,$newKey,$changed); END';
          }
          for (final sql in statements.values) {
            await database.execute(sql);
          }
          final stored = await database
              .query("SELECT name,sql FROM sqlite_schema WHERE type='trigger'");
          final actual = {
            for (final row in stored.rows)
              if (statements.containsKey(row[0]))
                row[0] as String: row[1] as String
          };
          await database.execute(
              'UPDATE _spc_sources SET triggers_json=? WHERE id=?',
              [jsonEncode(actual), id]);
          await _verifySources();
        });
        _notify(state.at(state.head), reset: true);
      });

  /// Stops future tracking, retaining metadata needed to decode existing events.
  Future<void> untrack(String table) => _run(() async {
        final state = await _state();
        final sources = await _sources(enabledOnly: true);
        final matches = sources.where((s) => s.name == table).toList();
        if (matches.length != 1) throw ArgumentError('Table is not tracked');
        final source = matches.single;
        await _atomic(() async {
          for (final name in source.triggers.keys) {
            await database.execute('DROP TRIGGER IF EXISTS ${_quote(name)}');
          }
          await database.execute(
              'UPDATE _spc_sources SET enabled=0 WHERE id=?', [source.id]);
        });
        _notify(state.at(state.head), reset: true);
      });
}
