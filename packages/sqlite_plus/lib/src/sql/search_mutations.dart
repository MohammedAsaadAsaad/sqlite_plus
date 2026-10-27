part of 'image_mutations.dart';

/// FTS and R-tree writes rebuild compact shadow tables. Unimplemented options
/// throw before any of those tables change.
extension _SearchMutations on ImageMutations {
  ImageObject? _searchTarget(String name) {
    final object = other
        .where((entry) =>
            entry.virtualTable && asciiLower(entry.name) == asciiLower(name))
        .firstOrNull;
    final sql = object?.sql;
    if (sql == null || !VirtualTableDeclaration.isVirtual(sql)) return null;
    final module = asciiLower(VirtualTableDeclaration.parse(sql).module);
    if (!['fts3', 'fts4', 'fts5', 'rtree', 'geopoly'].contains(module)) {
      return null;
    }
    return object;
  }

  Future<void> _installSearchShadows(
      VirtualTableModule module, VirtualTableDeclaration declaration) async {
    if (module is Fts5Module) {
      await _installFts5(
          Fts5Spec.parse(declaration.name, declaration.arguments));
    } else if (module is RtreeModule || module is GeopolyModule) {
      await _installRtree(RtreeSpec.parse(
          declaration.name, declaration.arguments,
          geopoly: module is GeopolyModule));
    }
  }

  void _dropSearchShadows(
      VirtualTableModule module, VirtualTableDeclaration declaration) {
    for (final name
        in module.ownedShadows(declaration.name, declaration.arguments)) {
      final key = asciiLower(name);
      _tables.remove(key);
      _indexes.removeWhere((index) => asciiLower(index.table) == key);
      _sequences.remove(key);
    }
  }

  Future<MutationImage> _searchWrite(String sql, List<Object?> parameters,
      {required bool compileOnly}) async {
    final parser = SqlParser(sql);
    if (parser.take('WITH')) {
      throw const SqlException('search WITH is not implemented');
    }
    var replace = parser.take('REPLACE');
    final insert = replace || parser.take('INSERT');
    final update = !insert && parser.take('UPDATE');
    if (!insert && !update) parser.require('DELETE');
    if (!replace && (insert || update) && parser.take('OR')) {
      final policy = parser.identifier().toUpperCase();
      if (policy == 'REPLACE') replace = true;
      if (!['ABORT', 'IGNORE', 'REPLACE', 'FAIL', 'ROLLBACK']
          .contains(policy)) {
        throw const SqlException('Unsupported conflict policy');
      }
      if (policy == 'IGNORE') replace = false;
    }
    if (insert) parser.require('INTO');
    if (!insert && !update) parser.require('FROM');
    final name = parser.qualifiedIdentifier();
    if (parser.take('AS')) parser.identifier();
    if (!insert && (parser.take('INDEXED') || parser.take('NOT'))) {
      throw const SqlException(
          'INDEXED BY is not implemented for search tables');
    }
    final object = _searchTarget(name);
    if (object == null) throw SqlException('No such table: $name');
    final declaration = VirtualTableDeclaration.parse(object.sql!);
    final module = VirtualTableRegistry.current?.find(declaration.module);
    if (module == null) {
      throw SqlException('No such module: ${declaration.module}');
    }
    if (module is Fts3Module) {
      throw const SqlException('FTS3 and FTS4 writes are not implemented');
    }
    if (module is Fts5Module) {
      return _writeFts5(parser, declaration, parameters,
          insert: insert,
          update: update,
          replace: replace,
          compileOnly: compileOnly);
    }
    return _writeRtree(parser, declaration, parameters,
        insert: insert,
        update: update,
        replace: replace,
        geopoly: module is GeopolyModule,
        compileOnly: compileOnly);
  }

  Future<MutationImage> _writeFts5(SqlParser parser,
      VirtualTableDeclaration declaration, List<Object?> parameters,
      {required bool insert,
      required bool update,
      required bool replace,
      required bool compileOnly}) async {
    final spec = Fts5Spec.parse(declaration.name, declaration.arguments);
    if (parser.take('RETURNING') ||
        parser.current.keyword == 'ORDER' ||
        parser.current.keyword == 'LIMIT') {
      throw const SqlException('search statement is not implemented');
    }
    final docs = _loadFts(spec);
    var changes = 0;
    BigInt? last;
    if (insert) {
      final plan = _ftsInsert(parser, spec, parameters);
      parser.finish();
      _parameterCount(parser, parameters);
      if (compileOnly) return MutationImage(original, 0, null);
      if (plan.command != null) {
        if (plan.command == 'delete-all') {
          changes = docs.length;
          docs.clear();
        } else if (plan.command == 'rebuild') {
          if (spec.contentless && !spec.external) {
            throw const SqlException('fts5 rebuild requires stored content');
          }
          docs
            ..clear()
            ..addAll(_loadFts(spec, liveExternal: true));
          changes = docs.isEmpty ? 1 : docs.length;
        } else {
          throw SqlException(
              'fts5 command is not implemented: ${plan.command}');
        }
      } else {
        for (final row in plan.rows) {
          final id = row.id ?? _nextId(docs.map((doc) => doc.id));
          if (id.isNegative) {
            throw const SqlException('FTS5 rowid must be nonnegative');
          }
          final existing = docs.indexWhere((doc) => doc.id == id);
          if (existing >= 0) {
            if (!replace) {
              throw const SqlException('UNIQUE constraint failed: fts5.rowid');
            }
            docs.removeAt(existing);
          }
          docs.add(_SearchDoc(id, row.texts, _tokens(spec, row.texts)));
          last = id;
          changes++;
        }
      }
    } else {
      final assignments =
          update ? _assignments(parser) : const <(String, Expr)>[];
      final where = parser.take('WHERE') ? parser.expression() : null;
      if (parser.take('ORDER') ||
          parser.take('LIMIT') ||
          parser.take('RETURNING')) {
        throw const SqlException('search statement is not implemented');
      }
      parser.finish();
      _parameterCount(parser, parameters);
      if (spec.contentless && !spec.contentlessDelete) {
        throw SqlException(update
            ? 'cannot UPDATE contentless fts5 table: ${spec.table}'
            : 'cannot DELETE from contentless fts5 table: ${spec.table}');
      }
      if (compileOnly) return MutationImage(original, 0, null);
      final state = _ftsState(spec, docs);
      ftsSession().tables[asciiLower(spec.table)] = state;
      final kept = <_SearchDoc>[];
      for (final doc in docs) {
        if (!_matches(spec, doc, where, parameters)) {
          kept.add(doc);
          continue;
        }
        changes++;
        if (!update) continue;
        final texts = [...doc.texts];
        final row = _ftsRow(spec, doc);
        final assigned = <int>{};
        for (final assignment in assignments) {
          final key = asciiLower(assignment.$1);
          if (key == 'rank' || key == asciiLower(spec.table)) {
            throw const SqlException('fts5 column cannot be updated');
          }
          final index = spec.visibleNames
              .indexWhere((column) => asciiLower(column) == key);
          if (index < 0 && !['rowid', '_rowid_', 'oid'].contains(key)) {
            throw SqlException('no such column: ${assignment.$1}');
          }
          final value = assignment.$2.evaluate(
              EvalContext(row, const <String, String>{}, parameters, encoding));
          if (index >= 0) {
            texts[index] = _searchText(value);
            assigned.add(index);
          }
        }
        final tokens = [
          for (var i = 0; i < spec.columns.length; i++)
            !assigned.contains(i)
                ? doc.tokens[i]
                : texts[i] == null
                    ? const <FtsToken>[]
                    : spec.columns[i].unindexed
                        ? const <FtsToken>[]
                        : spec.tokenizer.tokenize(texts[i]!)
        ];
        kept.add(_SearchDoc(doc.id, texts, tokens));
      }
      docs
        ..clear()
        ..addAll(kept);
    }
    if (changes == 0) return MutationImage(original, 0, null);
    _beginCounters();
    for (var i = 0; i < changes; i++) {
      _changed(insertedRowid: last);
    }
    _storeFts(spec, docs);
    return MutationImage(serialize(), changes, insert ? last : null);
  }

  Future<MutationImage> _writeRtree(SqlParser parser,
      VirtualTableDeclaration declaration, List<Object?> parameters,
      {required bool insert,
      required bool update,
      required bool replace,
      required bool geopoly,
      required bool compileOnly}) async {
    final spec = RtreeSpec.parse(declaration.name, declaration.arguments,
        geopoly: geopoly);
    final rows = _loadShapes(spec);
    var changes = 0;
    BigInt? last;
    if (insert) {
      final columns = parser.take('(') ? _nameList(parser) : spec.names;
      if (parser.take('SELECT') || parser.take('DEFAULT')) {
        throw const SqlException('search statement is not implemented');
      }
      final tuples = _valueTuples(parser);
      if (parser.take('ON') || parser.take('RETURNING')) {
        throw const SqlException('search statement is not implemented');
      }
      parser.finish();
      _parameterCount(parser, parameters);
      if (compileOnly) return MutationImage(original, 0, null);
      for (final tuple in tuples) {
        if (tuple.length != columns.length) {
          throw const SqlException('search column count mismatch');
        }
        final values = <String, Object?>{};
        for (var i = 0; i < columns.length; i++) {
          values[asciiLower(columns[i])] = tuple[i].evaluate(EvalContext(
              const <String, Object?>{},
              const <String, String>{},
              parameters,
              encoding));
        }
        final id = _shapeId(spec, values, rows, geopoly);
        if (!geopoly && rows.any((row) => row.id == id)) {
          if (!replace) {
            throw const SqlException('UNIQUE constraint failed: rtree.rowid');
          }
          rows.removeWhere((row) => row.id == id);
        }
        rows.add(_shapeFrom(spec, id, values, geopoly));
        last = id;
        changes++;
      }
    } else {
      final assignments =
          update ? _assignments(parser) : const <(String, Expr)>[];
      final where = parser.take('WHERE') ? parser.expression() : null;
      if (parser.take('ORDER') ||
          parser.take('LIMIT') ||
          parser.take('RETURNING')) {
        throw const SqlException('search statement is not implemented');
      }
      parser.finish();
      _parameterCount(parser, parameters);
      if (compileOnly) return MutationImage(original, 0, null);
      final kept = <_ShapeRow>[];
      for (final row in rows) {
        final context = EvalContext(_shapeValues(spec, row),
            const <String, String>{}, parameters, encoding);
        if (where != null && truth(where.evaluate(context), encoding) != true) {
          kept.add(row);
          continue;
        }
        changes++;
        if (!update) continue;
        final values = _shapeValues(spec, row);
        for (final assignment in assignments) {
          final key = asciiLower(assignment.$1);
          if (!values.containsKey(key) &&
              !['rowid', '_rowid_', 'oid'].contains(key)) {
            throw SqlException('no such column: ${assignment.$1}');
          }
          values[key] = assignment.$2.evaluate(context);
        }
        kept.add(_shapeFrom(
            spec,
            _shapeId(spec, values, const [], geopoly, fallback: row.id),
            values,
            geopoly));
      }
      rows
        ..clear()
        ..addAll(kept);
    }
    if (changes == 0) return MutationImage(original, 0, null);
    _beginCounters();
    for (var i = 0; i < changes; i++) {
      _changed(insertedRowid: last);
    }
    _storeShapes(spec, rows);
    return MutationImage(serialize(), changes, insert ? last : null);
  }

  Future<void> _installFts5(Fts5Spec spec) async {
    if (spec.external && !_tables.containsKey(asciiLower(spec.contentTable!))) {
      throw SqlException('no such table: ${spec.contentTable}');
    }
    final table = spec.table;
    await execute(
        'CREATE TABLE ${_q('${table}_data')}(id INTEGER PRIMARY KEY, block BLOB)',
        const []);
    await execute(
        'CREATE TABLE ${_q('${table}_idx')}(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID',
        const []);
    if (!spec.contentless && !spec.external) {
      final columns =
          [for (var i = 0; i < spec.columns.length; i++) 'c$i'].join(', ');
      await execute(
          'CREATE TABLE ${_q('${table}_content')}(id INTEGER PRIMARY KEY, $columns)',
          const []);
    }
    if (spec.columnSize) {
      final origin = spec.contentlessDelete ? ', origin INTEGER' : '';
      await execute(
          'CREATE TABLE ${_q('${table}_docsize')}(id INTEGER PRIMARY KEY, sz BLOB$origin)',
          const []);
    }
    await execute(
        'CREATE TABLE ${_q('${table}_config')}(k PRIMARY KEY, v) WITHOUT ROWID',
        const []);
    _replace('${table}_config', [
      (BigInt.one, {'k': 'version', 'v': BigInt.from(4)})
    ]);
    _storeFts(spec, const []);
  }

  Future<void> _installRtree(RtreeSpec spec) async {
    final coordinates = spec.geopoly ? 4 : spec.coordinates;
    final table = spec.table;
    await execute(
        'CREATE TABLE ${_q('${table}_node')}(nodeno INTEGER PRIMARY KEY, data)',
        const []);
    await execute(
        'CREATE TABLE ${_q('${table}_parent')}(nodeno INTEGER PRIMARY KEY, parentnode)',
        const []);
    final extras = spec.geopoly
        ? [for (var i = 0; i < spec.columns.length; i++) ', a$i'].join()
        : [
            for (var i = 0;
                i < spec.columns.where((column) => column.auxiliary).length;
                i++)
              ', a$i'
          ].join();
    await execute(
        'CREATE TABLE ${_q('${table}_rowid')}(rowid INTEGER PRIMARY KEY, nodeno$extras)',
        const []);
    _storeShapes(spec, const []);
    final size = rtreeNodeSize(_pageSize, coordinates);
    _replace('${table}_node', [
      (BigInt.one, {'data': encodeRtreeNode(0, const [], size)})
    ]);
  }

  void _storeFts(Fts5Spec spec, List<_SearchDoc> docs) {
    final ordered = [...docs]..sort((a, b) => a.id.compareTo(b.id));
    final leaves = <(BigInt, Uint8List)>[];
    final index = <(BigInt, Map<String, Object?>)>[];
    final segments = <FtsSegmentRef>[];
    final totals = List<int>.filled(spec.columns.length, 0);
    for (var i = 0; i < ordered.length; i++) {
      final doc = ordered[i];
      for (var column = 0; column < spec.columns.length; column++) {
        if (!spec.columns[column].unindexed) {
          totals[column] += doc.tokens[column].length;
        }
      }
      final segid = i + 1;
      final leaf = _ftsLeaf(spec, doc);
      leaves.add((BigInt.from(fts5LeafRowid(segid, 1)), leaf));
      index.add((
        BigInt.from(segid),
        {'segid': BigInt.from(segid), 'term': Uint8List(0), 'pgno': BigInt.two}
      ));
      segments.add(FtsSegmentRef(segid, 1, 1,
          origin1: segid, origin2: segid, entries: 1));
    }
    final data = <(BigInt, Map<String, Object?>)>[
      (BigInt.one, {'block': encodeAverages(ordered.length, totals)}),
      (
        BigInt.from(10),
        {'block': encodeStructure(segments, version2: spec.contentlessDelete)}
      ),
      for (final leaf in leaves) (leaf.$1, {'block': leaf.$2})
    ];
    _replace('${spec.table}_data', data);
    _replace('${spec.table}_idx', index);
    if (!spec.contentless && !spec.external) {
      _replace('${spec.table}_content', [
        for (final doc in ordered)
          (
            doc.id,
            {for (var i = 0; i < doc.texts.length; i++) 'c$i': doc.texts[i]}
          )
      ]);
    }
    if (spec.columnSize) {
      _replace('${spec.table}_docsize', [
        for (var i = 0; i < ordered.length; i++)
          (
            ordered[i].id,
            {
              'sz': encodeDocsize([
                for (var column = 0; column < spec.columns.length; column++)
                  spec.columns[column].unindexed
                      ? 0
                      : ordered[i].tokens[column].length
              ]),
              if (spec.contentlessDelete) 'origin': BigInt.from(i + 1)
            }
          )
      ]);
    }
  }

  Uint8List _ftsLeaf(Fts5Spec spec, _SearchDoc doc) {
    final terms = <String, Map<int, List<int>>>{};
    void add(int prefix, String text, int column, int position) {
      if (text.isEmpty) return;
      final key = String.fromCharCodes(fts5Term(prefix, text));
      terms
          .putIfAbsent(key, () => {})
          .putIfAbsent(column, () => [])
          .add(position);
    }

    for (var column = 0; column < spec.columns.length; column++) {
      if (spec.columns[column].unindexed) continue;
      final tokens = doc.tokens[column];
      for (var position = 0; position < tokens.length; position++) {
        final text = tokens[position].text;
        add(0, text, column, position);
        for (var i = 0; i < spec.prefix.length; i++) {
          add(i + 1, ftsPrefixChars(text, spec.prefix[i]), column, position);
        }
      }
    }
    return encodeLeaf([
      for (final entry in terms.entries)
        FtsPosting(Uint8List.fromList(entry.key.codeUnits),
            [FtsRowPosting(doc.id, entry.value)])
    ]);
  }

  List<_SearchDoc> _loadFts(Fts5Spec spec, {bool liveExternal = false}) {
    if (!spec.contentless && !spec.external) {
      final content = _tables[asciiLower('${spec.table}_content')];
      if (content == null) return [];
      return [
        for (final row in content.rows)
          _SearchDoc(row.rowId, _contentTexts(spec, row),
              _tokens(spec, _contentTexts(spec, row)))
      ];
    }
    if (liveExternal && spec.external) {
      final table = _tables[asciiLower(spec.contentTable!)];
      if (table == null) return [];
      return [
        for (final row in table.rows)
          if (_externalKey(table, row, spec.contentRowid) != null)
            _SearchDoc(
                _externalKey(table, row, spec.contentRowid)!,
                _externalTexts(table, row, spec.columns.length),
                _tokens(spec, _externalTexts(table, row, spec.columns.length)))
      ];
    }
    final indexed = readFts5Documents(
        spec, _searchSnapshot(['${spec.table}_data', '${spec.table}_idx']));
    final docsize =
        spec.columnSize ? _tables[asciiLower('${spec.table}_docsize')] : null;
    final ids = docsize == null
        ? indexed.keys.toList()
        : [for (final row in docsize.rows) row.rowId];
    return [
      for (final id in ids)
        _SearchDoc(id, List<String?>.filled(spec.columns.length, null), [
          for (final column in indexed[id]?.tokens ??
              List<List<FtsToken>>.filled(
                  spec.columns.length, const <FtsToken>[]))
            _compact(column)
        ])
    ];
  }

  SearchSnapshot _searchSnapshot(List<String> names) {
    final tables = <String, ShadowTable>{};
    for (final name in names) {
      final loaded = _tables[asciiLower(name)];
      if (loaded == null) continue;
      tables[name] = ShadowTable(
          loaded.schema.columns.map((column) => column.name).toList(),
          [for (final row in loaded.rows) ShadowRow(row.rowId, row.values)],
          rowidAlias: loaded.schema.rowidAlias);
    }
    return SearchSnapshot(tables);
  }

  _FtsInsert _ftsInsert(
      SqlParser parser, Fts5Spec spec, List<Object?> parameters) {
    final columns = parser.take('(') ? _nameList(parser) : spec.visibleNames;
    if (parser.take('SELECT') || parser.take('DEFAULT')) {
      throw const SqlException('search statement is not implemented');
    }
    final tuples = _valueTuples(parser);
    if (parser.take('ON') || parser.take('RETURNING')) {
      throw const SqlException('search statement is not implemented');
    }
    if (columns.length == 1 &&
        asciiLower(columns.single) == asciiLower(spec.table)) {
      if (tuples.length != 1 || tuples.single.length != 1) {
        throw const SqlException('fts5 command is not implemented');
      }
      final value = tuples.single.single.evaluate(EvalContext(
          const <String, Object?>{},
          const <String, String>{},
          parameters,
          encoding));
      final command = _searchText(value);
      if (command == 'rebuild' || command == 'delete-all') {
        return _FtsInsert(command, const []);
      }
      throw SqlException('fts5 command is not implemented: $command');
    }
    final rows = <_FtsInput>[];
    for (final tuple in tuples) {
      if (tuple.length != columns.length) {
        throw const SqlException('search column count mismatch');
      }
      final texts = List<String?>.filled(spec.columns.length, null);
      BigInt? id;
      for (var i = 0; i < columns.length; i++) {
        final key = asciiLower(columns[i]);
        final value = tuple[i].evaluate(EvalContext(const <String, Object?>{},
            const <String, String>{}, parameters, encoding));
        if (['rowid', '_rowid_', 'oid'].contains(key)) {
          id = _rowidValue(value);
          continue;
        }
        final index =
            spec.visibleNames.indexWhere((column) => asciiLower(column) == key);
        if (index < 0) throw SqlException('no such column: ${columns[i]}');
        texts[index] = _searchText(value);
      }
      rows.add(_FtsInput(id, texts));
    }
    return _FtsInsert(null, rows);
  }

  List<(String, Expr)> _assignments(SqlParser parser) {
    parser.require('SET');
    final assignments = <(String, Expr)>[];
    do {
      final name = parser.identifier();
      parser.require('=');
      assignments.add((name, parser.expression()));
    } while (parser.take(','));
    return assignments;
  }

  List<String> _nameList(SqlParser parser) {
    final names = <String>[];
    do {
      names.add(parser.identifier());
    } while (parser.take(','));
    parser.require(')');
    return names;
  }

  List<List<Expr>> _valueTuples(SqlParser parser) {
    parser.require('VALUES');
    final rows = <List<Expr>>[];
    do {
      parser.require('(');
      final values = <Expr>[];
      if (!parser.take(')')) {
        do {
          values.add(parser.expression());
        } while (parser.take(','));
        parser.require(')');
      }
      rows.add(values);
    } while (parser.take(','));
    return rows;
  }

  void _parameterCount(SqlParser parser, List<Object?> parameters) {
    if (parser.parameterCount != parameters.length) {
      throw const SqlException('Incorrect parameter count');
    }
  }

  bool _matches(
      Fts5Spec spec, _SearchDoc doc, Expr? where, List<Object?> parameters) {
    if (where == null) return true;
    return truth(
            where.evaluate(EvalContext(_ftsRow(spec, doc),
                const <String, String>{}, parameters, encoding)),
            encoding) ==
        true;
  }

  Map<String, Object?> _ftsRow(Fts5Spec spec, _SearchDoc doc) => {
        'rowid': doc.id,
        '_rowid_': doc.id,
        'oid': doc.id,
        for (var i = 0; i < spec.visibleNames.length; i++)
          asciiLower(spec.visibleNames[i]): doc.texts[i],
        asciiLower(spec.table): null,
        'rank': null
      };

  FtsTableState _ftsState(Fts5Spec spec, List<_SearchDoc> docs) {
    final documents = {
      for (final doc in docs)
        doc.id: FtsDocument(doc.id, doc.texts, doc.tokens,
            [for (final column in spec.columns) column.unindexed])
    };
    return FtsTableState(spec, documents);
  }

  List<String?> _contentTexts(Fts5Spec spec, TableRow row) => [
        for (var i = 0; i < spec.columns.length; i++)
          _searchText(row.values.length > i + 1 ? row.values[i + 1] : null)
      ];

  List<String?> _externalTexts(_Table table, TableRow row, int count) {
    final texts = <String?>[];
    for (final column in table.schema.columns) {
      if (table.schema.rowidAlias != null &&
          column.name == table.schema.rowidAlias) {
        continue;
      }
      final index = table.schema.columns.indexOf(column);
      texts.add(_searchText(row.values[index]));
      if (texts.length == count) break;
    }
    while (texts.length < count) {
      texts.add(null);
    }
    return texts;
  }

  BigInt? _externalKey(_Table table, TableRow row, String name) {
    if (['rowid', '_rowid_', 'oid'].contains(asciiLower(name)) ||
        table.schema.rowidAlias != null &&
            asciiLower(table.schema.rowidAlias!) == asciiLower(name)) {
      return row.rowId;
    }
    final index = table.schema.columns
        .indexWhere((column) => asciiLower(column.name) == asciiLower(name));
    if (index < 0) return null;
    return _rowidValue(row.values[index]);
  }

  List<List<FtsToken>> _tokens(Fts5Spec spec, List<String?> texts) => [
        for (var i = 0; i < spec.columns.length; i++)
          spec.columns[i].unindexed || texts[i] == null
              ? const <FtsToken>[]
              : spec.tokenizer.tokenize(texts[i]!)
      ];

  List<_ShapeRow> _loadShapes(RtreeSpec spec) {
    final coordinates = spec.geopoly ? 4 : spec.coordinates;
    final cells = rtreeLeaves(
        _searchSnapshot(['${spec.table}_node']), spec.table, coordinates);
    final rowids = _tables[asciiLower('${spec.table}_rowid')];
    final byId = <BigInt, TableRow>{};
    if (rowids != null) {
      for (final row in rowids.rows) {
        byId[row.rowId] = row;
      }
    }
    if (spec.geopoly) {
      final loaded = <_ShapeRow>[];
      for (final row in rowids?.rows ?? const <TableRow>[]) {
        final values = row.values;
        loaded.add(_ShapeRow(row.rowId, values.length > 2 ? values[2] : null,
            [for (var i = 3; i < values.length; i++) values[i]], const []));
      }
      return loaded;
    }
    return [
      for (final cell in cells)
        _ShapeRow(
            BigInt.from(cell.rowId),
            null,
            [
              for (var i = 2;
                  i < (byId[BigInt.from(cell.rowId)]?.values.length ?? 2);
                  i++)
                byId[BigInt.from(cell.rowId)]!.values[i]
            ],
            cell.coords)
    ];
  }

  void _storeShapes(RtreeSpec spec, List<_ShapeRow> rows) {
    final coordinates = spec.geopoly ? 4 : spec.coordinates;
    final size = _nodeSize(spec.table, coordinates);
    final cells = <RtreeCell>[];
    final stored = <_ShapeRow>[];
    if (spec.geopoly) {
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final polygon = parseGeopoly(row.shape);
        final coords =
            polygon == null ? List<double>.filled(4, 0) : _bounds(polygon);
        final id = i + 1;
        cells.add(RtreeCell(id, coords));
        stored.add(_ShapeRow(BigInt.from(id), row.shape, row.extra, coords));
      }
    } else {
      for (final row in rows) {
        cells.add(RtreeCell(row.id.toInt(), row.coords));
        stored.add(row);
      }
    }
    final capacity = (size - 4) ~/ (8 + coordinates * 4);
    if (cells.length <= capacity) {
      _replace('${spec.table}_node', [
        (BigInt.one, {'data': encodeRtreeNode(0, cells, size)})
      ]);
      _replace('${spec.table}_parent', const []);
      _replace('${spec.table}_rowid', [
        for (final row in stored)
          (
            row.id,
            {
              'nodeno': BigInt.one,
              if (spec.geopoly) 'a0': row.shape,
              for (var i = 0; i < row.extra.length; i++)
                'a${spec.geopoly ? i + 1 : i}': row.extra[i]
            }
          )
      ]);
      return;
    }
    final leaves = <(int, List<RtreeCell>)>[];
    for (var start = 0; start < cells.length; start += capacity) {
      final end =
          start + capacity > cells.length ? cells.length : start + capacity;
      leaves.add((leaves.length + 2, cells.sublist(start, end)));
    }
    final root = <RtreeCell>[];
    final parents = <(BigInt, Map<String, Object?>)>[];
    for (final leaf in leaves) {
      final box = _union(leaf.$2, coordinates);
      root.add(RtreeCell(leaf.$1, box));
      parents.add((BigInt.from(leaf.$1), {'parentnode': BigInt.one}));
    }
    _replace('${spec.table}_node', [
      (BigInt.one, {'data': encodeRtreeNode(1, root, size)}),
      for (final leaf in leaves)
        (BigInt.from(leaf.$1), {'data': encodeRtreeNode(0, leaf.$2, size)})
    ]);
    _replace('${spec.table}_parent', parents);
    final leafOf = <int, int>{};
    for (final leaf in leaves) {
      for (final cell in leaf.$2) {
        leafOf[cell.rowId] = leaf.$1;
      }
    }
    _replace('${spec.table}_rowid', [
      for (final row in stored)
        (
          row.id,
          {
            'nodeno': BigInt.from(leafOf[row.id.toInt()] ?? 1),
            if (spec.geopoly) 'a0': row.shape,
            for (var i = 0; i < row.extra.length; i++)
              'a${spec.geopoly ? i + 1 : i}': row.extra[i]
          }
        )
    ]);
  }

  int _nodeSize(String table, int coordinates) {
    final node = _tables[asciiLower('${table}_node')];
    final existing = node?.rows
        .where((row) => row.rowId == BigInt.one)
        .firstOrNull
        ?.values
        .elementAtOrNull(1);
    if (existing is Uint8List && existing.isNotEmpty) return existing.length;
    return rtreeNodeSize(_pageSize, coordinates);
  }

  int get _pageSize => DatabaseHeader.decode(original).pageSize;

  _ShapeRow _shapeFrom(
      RtreeSpec spec, BigInt id, Map<String, Object?> values, bool geopoly) {
    if (geopoly) {
      final shape = values['_shape'];
      final extra = [
        for (final column in spec.names.skip(1)) values[asciiLower(column)]
      ];
      return _ShapeRow(id, shape, extra, _bounds(parseGeopoly(shape)));
    }
    final coords = <double>[];
    final extra = <Object?>[];
    for (final column in spec.columns.skip(1)) {
      final value = values[asciiLower(column.name)];
      if (column.auxiliary) {
        extra.add(value);
      } else {
        coords.add(_coordinate(value));
      }
    }
    return _ShapeRow(id, null, extra, coords);
  }

  Map<String, Object?> _shapeValues(RtreeSpec spec, _ShapeRow row) {
    if (spec.geopoly) {
      return {
        'rowid': row.id,
        '_rowid_': row.id,
        'oid': row.id,
        '_shape': row.shape,
        for (var i = 1; i < spec.names.length; i++)
          asciiLower(spec.names[i]):
              i - 1 < row.extra.length ? row.extra[i - 1] : null
      };
    }
    final values = <String, Object?>{
      'rowid': row.id,
      '_rowid_': row.id,
      'oid': row.id,
      asciiLower(spec.names.first): row.id
    };
    var coordinate = 0;
    var auxiliary = 0;
    for (final column in spec.columns.skip(1)) {
      values[asciiLower(column.name)] = column.auxiliary
          ? (auxiliary < row.extra.length ? row.extra[auxiliary++] : null)
          : row.coords[coordinate++];
    }
    return values;
  }

  BigInt _shapeId(RtreeSpec spec, Map<String, Object?> values,
      List<_ShapeRow> rows, bool geopoly,
      {BigInt? fallback}) {
    if (geopoly) {
      return fallback ?? _nextId(rows.map((row) => row.id));
    }
    final value =
        values[asciiLower(spec.names.first)] ?? values['rowid'] ?? fallback;
    if (value == null) return _nextId(rows.map((row) => row.id));
    return _rowidValue(value);
  }

  void _replace(String name, List<(BigInt, Map<String, Object?>)> rows) {
    final table = _tables[asciiLower(name)];
    if (table == null) throw SqlException('No such table: $name');
    table.rows
      ..clear()
      ..addAll([for (final row in rows) _physical(table, row.$2, row.$1)]);
  }

  String _q(String name) => '"${name.replaceAll('"', '""')}"';
}

final class _SearchDoc {
  _SearchDoc(this.id, this.texts, this.tokens);
  final BigInt id;
  final List<String?> texts;
  final List<List<FtsToken>> tokens;
}

final class _FtsInput {
  _FtsInput(this.id, this.texts);
  final BigInt? id;
  final List<String?> texts;
}

final class _FtsInsert {
  _FtsInsert(this.command, this.rows);
  final String? command;
  final List<_FtsInput> rows;
}

final class _ShapeRow {
  _ShapeRow(this.id, this.shape, this.extra, this.coords);
  final BigInt id;
  final Object? shape;
  final List<Object?> extra;
  final List<double> coords;
}

List<FtsToken> _compact(List<FtsToken> tokens) {
  final kept = tokens.where((token) => token.text.isNotEmpty).toList();
  return [
    for (var i = 0; i < kept.length; i++)
      FtsToken(kept[i].text, i, i + kept[i].text.length)
  ];
}

BigInt _nextId(Iterable<BigInt> ids) {
  var max = BigInt.zero;
  for (final id in ids) {
    if (id > max) max = id;
  }
  return max + BigInt.one;
}

BigInt _rowidValue(Object? value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is String) {
    final parsed = BigInt.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw const SqlException('search rowid is not an integer');
}

String? _searchText(Object? value) {
  if (value == null || value is Uint8List) return null;
  if (value is String) return value;
  return value.toString();
}

double _coordinate(Object? value) {
  if (value is double) return value;
  if (value is BigInt) return value.toDouble();
  if (value is int) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw const SqlException('rtree coordinate is not numeric');
}

List<double> _bounds(GeoPolygon? polygon) {
  if (polygon == null || polygon.vertices.isEmpty) {
    return List<double>.filled(4, 0);
  }
  var minX = polygon.vertices.first.$1;
  var maxX = minX;
  var minY = polygon.vertices.first.$2;
  var maxY = minY;
  for (final vertex in polygon.vertices) {
    if (vertex.$1 < minX) minX = vertex.$1;
    if (vertex.$1 > maxX) maxX = vertex.$1;
    if (vertex.$2 < minY) minY = vertex.$2;
    if (vertex.$2 > maxY) maxY = vertex.$2;
  }
  return [minX, maxX, minY, maxY];
}

List<double> _union(List<RtreeCell> cells, int coordinates) {
  final box = [...cells.first.coords];
  for (final cell in cells.skip(1)) {
    for (var i = 0; i < coordinates; i += 2) {
      if (cell.coords[i] < box[i]) box[i] = cell.coords[i];
      if (cell.coords[i + 1] > box[i + 1]) box[i + 1] = cell.coords[i + 1];
    }
  }
  return box;
}
