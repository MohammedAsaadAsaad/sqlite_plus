import 'dart:typed_data';

import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import 'catalog.dart';
import 'fts5_format.dart';
import 'fts_text.dart';
import 'functions.dart';
import 'parser.dart';
import 'search_runtime.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'virtual_table.dart';

void registerSearchModules(VirtualTableRegistry registry) {
  registry.register(Fts5Module());
  registry.register(Fts3Module(false));
  registry.register(Fts4Module());
  registry.register(RtreeModule());
  registry.register(GeopolyModule());
}

Future<SearchSnapshot> readSearchShadows(
    ReadOnlyPager pager, DatabaseCatalog catalog, CatalogTable table) async {
  final moduleName = table.virtualModule;
  if (moduleName == null) return SearchSnapshot.empty;
  final module = VirtualTableRegistry.current?.find(moduleName);
  if (module == null) return SearchSnapshot.empty;
  final names = module.shadowNames(table.name, table.virtualArguments);
  if (names.isEmpty) return SearchSnapshot.empty;
  final tables = <String, ShadowTable>{};
  for (final name in names) {
    final loaded = await _shadow(pager, catalog, name);
    if (loaded != null) tables[name] = loaded;
  }
  return SearchSnapshot(tables);
}

Future<ShadowTable?> _shadow(
    ReadOnlyPager pager, DatabaseCatalog catalog, String name) async {
  final entry = catalog.entries
      .where((item) =>
          item.type == 'table' && asciiLower(item.name) == asciiLower(name))
      .firstOrNull;
  if (entry == null || entry.rootPage == 0 || entry.sql == null) return null;
  if (VirtualTableDeclaration.isVirtual(entry.sql)) return null;
  final schema = catalog.table(name);
  final reader = BtreeReader(pager);
  final rows = <ShadowRow>[];
  final stream = schema.withoutRowid
      ? reader.scanIndex(schema.rootPage)
      : reader.scanTable(schema.rootPage);
  await for (final record in stream) {
    final values = List<Object?>.filled(schema.columns.length, null);
    final stored = schema.storageColumns;
    for (var i = 0; i < stored.length && i < record.values.length; i++) {
      values[schema.columns.indexOf(stored[i])] = record.values[i];
    }
    rows.add(ShadowRow(record.rowId ?? BigInt.from(rows.length + 1), values));
  }
  return ShadowTable(schema.columns.map((column) => column.name).toList(), rows,
      rowidAlias: schema.rowidAlias);
}

final class Fts5Module extends VirtualTableModule {
  final scans = <String, (Expr?, List<Object?>)>{};

  @override
  String get name => 'fts5';
  @override
  List<String> get columns => const ['fts5'];
  @override
  List<String> get hiddenColumns => const ['rank'];

  @override
  void prepareScan(CatalogTable table, Expr? where, List<Object?> parameters) {
    scans[asciiLower(table.name)] = (where, parameters);
  }

  @override
  void xCreate(String table, List<String> arguments) {
    Fts5Spec.parse(table, arguments);
  }

  @override
  List<String> columnsFor(String table, List<String> arguments) =>
      Fts5Spec.parse(table, arguments).visibleNames;

  @override
  List<String> hiddenFor(String table, List<String> arguments) =>
      [table, 'rank'];

  @override
  List<String> shadowNames(String table, List<String> arguments) {
    final spec = Fts5Spec.parse(table, arguments);
    return [
      '${table}_data',
      '${table}_idx',
      if (!spec.contentless && !spec.external) '${table}_content',
      if (spec.columnSize) '${table}_docsize',
      '${table}_config',
      if (spec.contentTable != null) spec.contentTable!,
    ];
  }

  @override
  List<String> ownedShadows(String table, List<String> arguments) {
    final external = Fts5Spec.parse(table, arguments).contentTable;
    return [
      for (final name in shadowNames(table, arguments))
        if (external == null || asciiLower(name) != asciiLower(external)) name
    ];
  }

  @override
  VirtualTableCursor xOpen(String table) => _Fts5Cursor(this);
}

final class _Fts5Cursor extends VirtualTableCursor {
  _Fts5Cursor(this.module);
  final Fts5Module module;
  var _closed = false;
  var _index = 0;
  List<(BigInt, List<Object?>)> _rows = const [];

  void _live() {
    if (_closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    final spec = Fts5Spec.parse(table, arguments);
    final snapshot = SearchSnapshot.current;
    final documents = _documents(spec, snapshot);
    final scan = module.scans[asciiLower(table)];
    final pending = _pendingQuery(scan?.$1, scan?.$2 ?? const [], spec);
    final state = FtsTableState(spec, documents);
    if (pending != null) {
      final query =
          parseFtsQuery(pending.$1, spec.tokenizer, spec.visibleNames);
      state.query = query;
      state.column = pending.$2;
      state.bm25 = FtsBm25.build(query, documents.values.toList(), pending.$2);
      for (final document in documents.values) {
        if (!query.matches(document, column: pending.$2)) continue;
        final instances = query.instances(document, column: pending.$2);
        state.instances[document.rowId] = instances;
        state.scores[document.rowId] =
            state.bm25!.score(document, instances, const []);
      }
    }
    ftsSession().tables[asciiLower(spec.table)] = state;
    _rows = [
      for (final document in documents.values)
        (
          document.rowId,
          [
            for (var i = 0; i < spec.columns.length; i++) document.texts[i],
            null,
            state.scores[document.rowId],
          ]
        )
    ];
    _index = 0;
  }

  @override
  void next() {
    _live();
    if (_index < _rows.length) _index++;
  }

  @override
  bool get eof {
    _live();
    return _index >= _rows.length;
  }

  @override
  Object? column(int index) {
    _live();
    final row = _rows[_index];
    if (index < 0 || index >= row.$2.length) {
      throw const SqlException('Virtual table column index out of range');
    }
    return row.$2[index];
  }

  @override
  BigInt get rowid {
    _live();
    return _rows[_index].$1;
  }

  @override
  void close() {
    _closed = true;
    _rows = const [];
  }
}

(String, int?)? _pendingQuery(
    Expr? where, List<Object?> parameters, Fts5Spec spec) {
  FunctionExpr? match;
  void walk(Expr? expression) {
    if (match != null || expression == null) return;
    if (expression is FunctionExpr &&
        expression.key == 'match' &&
        expression.arguments.length == 2) {
      match = expression;
      return;
    }
    if (expression is UnaryExpr) {
      walk(expression.operand);
      return;
    }
    if (expression is BinaryExpr && expression.op == 'AND') {
      walk(expression.left);
      walk(expression.right);
    }
  }

  walk(where);
  final found = match;
  if (found == null) return null;
  final pattern = _constant(found.arguments[0], parameters);
  if (pattern == null) return null;
  final column = found.arguments[1];
  int? restriction;
  if (column is ColumnExpr &&
      asciiLower(column.name) != asciiLower(spec.table)) {
    final index = spec.visibleNames
        .indexWhere((name) => asciiLower(name) == asciiLower(column.name));
    if (index >= 0) restriction = index;
  }
  return (pattern, restriction);
}

String? _constant(Expr expression, List<Object?> parameters) {
  if (expression is Literal) return ftsPatternText(expression.value);
  if (expression is ParameterExpr) {
    if (expression.index < 0 || expression.index >= parameters.length) {
      return null;
    }
    return ftsPatternText(parameters[expression.index]);
  }
  if (expression is UnaryExpr &&
      (expression.op == '+' || expression.op == '-')) {
    return _constant(expression.operand, parameters);
  }
  if (expression is BinaryExpr && expression.op == '||') {
    final left = _constant(expression.left, parameters);
    final right = _constant(expression.right, parameters);
    if (left == null || right == null) return null;
    return left + right;
  }
  return null;
}

Map<BigInt, FtsDocument> readFts5Documents(
        Fts5Spec spec, SearchSnapshot snapshot) =>
    _documents(spec, snapshot);

Map<BigInt, FtsDocument> _documents(Fts5Spec spec, SearchSnapshot snapshot) {
  final indexed = _indexedTokens(spec, snapshot);
  final texts = <BigInt, List<String?>>{};
  if (!spec.contentless && !spec.external) {
    final content = snapshot.table('${spec.table}_content');
    if (content != null) {
      for (final row in content.rows) {
        texts[row.rowId] = [
          for (var i = 0; i < spec.columns.length; i++)
            _text(row.values.length > i + 1 ? row.values[i + 1] : null)
        ];
      }
    }
  } else if (spec.external && spec.contentTable != null) {
    final external = snapshot.table(spec.contentTable!);
    if (external != null) {
      for (final row in external.rows) {
        final key = _externalId(external, row, spec.contentRowid);
        if (key == null) continue;
        texts[key] = [
          for (var i = 0; i < spec.columns.length; i++)
            _text(_externalColumn(external, row, i))
        ];
      }
    }
  }
  final ids = {...indexed.keys, ...texts.keys}.toList()..sort();
  return {
    for (final id in ids)
      id: FtsDocument(
          id,
          texts[id] ?? List<String?>.filled(spec.columns.length, null),
          indexed[id] ??
              [
                for (var i = 0; i < spec.columns.length; i++) const <FtsToken>[]
              ],
          [for (final column in spec.columns) column.unindexed])
  };
}

Map<BigInt, List<List<FtsToken>>> _indexedTokens(
    Fts5Spec spec, SearchSnapshot snapshot) {
  final data = snapshot.table('${spec.table}_data');
  final index = snapshot.table('${spec.table}_idx');
  final byRow = <BigInt, List<Map<int, String>>>{};
  if (data == null || index == null) return const {};
  final blocks = <int, Uint8List>{};
  for (final row in data.rows) {
    final block = row.values.length > 1 ? row.values[1] : null;
    if (block is Uint8List && row.rowId > BigInt.from(100)) {
      blocks[row.rowId.toInt()] = block;
    }
  }
  final pages = <int, List<int>>{};
  for (final row in index.rows) {
    if (row.values.length < 3) continue;
    final segid = _int(row.values[0]);
    final page = _int(row.values[2]) >> 1;
    pages.putIfAbsent(segid, () => []).add(page);
  }
  final segids = pages.keys.toList()..sort();
  for (final segid in segids) {
    final ordered = pages[segid]!..sort();
    for (final page in ordered) {
      final block = blocks[fts5LeafRowid(segid, page)];
      if (block == null || block.length < 4) continue;
      List<FtsPosting> terms;
      try {
        terms = decodeLeaf(block);
      } on SqlException {
        continue;
      }
      for (final term in terms) {
        if (term.term.isEmpty || term.term[0] != 0x30) continue;
        final token = String.fromCharCodes(term.term.sublist(1));
        for (final posting in term.rows) {
          final columns =
              byRow.putIfAbsent(posting.rowId, () => <Map<int, String>>[]);
          if (posting.delete) {
            for (final positions in posting.positions.values) {
              for (final position in positions) {
                _clear(columns, posting, position);
              }
            }
            continue;
          }
          for (final entry in posting.positions.entries) {
            for (final position in entry.value) {
              _put(columns, entry.key, position, token);
            }
          }
        }
      }
    }
  }
  return {
    for (final entry in byRow.entries)
      entry.key: [
        for (var column = 0; column < spec.columns.length; column++)
          _columnTokens(entry.value, column)
      ]
  };
}

void _put(
    List<Map<int, String>> columns, int column, int position, String token) {
  while (columns.length <= column) {
    columns.add({});
  }
  columns[column][position] = token;
}

void _clear(
    List<Map<int, String>> columns, FtsRowPosting posting, int position) {
  if (posting.positions.isEmpty) {
    for (final column in columns) {
      column.remove(position);
    }
    return;
  }
}

List<FtsToken> _columnTokens(List<Map<int, String>> columns, int column) {
  if (column >= columns.length || columns[column].isEmpty) return const [];
  final slots = columns[column];
  final max = slots.keys.reduce((a, b) => a > b ? a : b);
  return [
    for (var i = 0; i <= max; i++)
      FtsToken(slots[i] ?? '', i, i + (slots[i]?.length ?? 0))
  ];
}

String? _text(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is Uint8List) return null;
  return value.toString();
}

BigInt? _externalId(ShadowTable table, ShadowRow row, String contentRowid) {
  final alias = table.rowidAlias;
  if (alias == null ||
      ['rowid', '_rowid_', 'oid', asciiLower(alias)]
          .contains(asciiLower(contentRowid))) {
    return row.rowId;
  }
  final value = table.value(row, contentRowid);
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  return null;
}

Object? _externalColumn(ShadowTable table, ShadowRow row, int index) {
  var seen = 0;
  for (var i = 0; i < table.columns.length; i++) {
    if (table.rowidAlias != null &&
        asciiLower(table.columns[i]) == asciiLower(table.rowidAlias!)) {
      continue;
    }
    if (seen == index) return row.values[i];
    seen++;
  }
  return null;
}

int _int(Object? value) {
  if (value is BigInt) return value.toInt();
  if (value is int) return value;
  return 0;
}

final class Fts3Module extends VirtualTableModule {
  Fts3Module(this.fts4);
  final bool fts4;
  final scans = <String, (Expr?, List<Object?>)>{};

  @override
  String get name => 'fts3';
  @override
  List<String> get columns => const ['fts3'];

  @override
  void prepareScan(CatalogTable table, Expr? where, List<Object?> parameters) {
    scans[asciiLower(table.name)] = (where, parameters);
  }

  @override
  void xCreate(String table, List<String> arguments) {
    throw const SqlException('FTS3 and FTS4 writes are not implemented');
  }

  @override
  List<String> columnsFor(String table, List<String> arguments) =>
      _fts3Columns(arguments);

  @override
  List<String> hiddenFor(String table, List<String> arguments) => [table];

  @override
  List<String> shadowNames(String table, List<String> arguments) => [
        '${table}_content',
        '${table}_segments',
        '${table}_segdir',
        if (fts4) ...['${table}_docsize', '${table}_stat']
      ];

  @override
  VirtualTableCursor xOpen(String table) => _Fts3Cursor(this);
}

final class Fts4Module extends Fts3Module {
  Fts4Module() : super(true);
  @override
  String get name => 'fts4';
  @override
  List<String> get columns => const ['fts4'];
}

List<String> _fts3Columns(List<String> arguments) {
  final columns = <String>[];
  for (final raw in arguments) {
    final argument = raw.trim();
    if (argument.contains('=')) continue;
    final name = argument.split(RegExp(r'\s+')).first;
    if (name.isNotEmpty) {
      columns.add(name.replaceAll("'", '').replaceAll('"', ''));
    }
  }
  if (columns.isEmpty) {
    throw const SqlException('vtable constructor failed: fts');
  }
  return columns;
}

FtsTokenizer _fts3Tokenizer(List<String> arguments) {
  for (final raw in arguments) {
    final argument = raw.trim();
    final index = argument.indexOf('=');
    if (index <= 0 || asciiLower(argument.substring(0, index)) != 'tokenize') {
      continue;
    }
    var value = argument.substring(index + 1).trim();
    if (value.length >= 2 &&
        (value.startsWith("'") || value.startsWith('"')) &&
        value.endsWith(value[0])) {
      value = value.substring(1, value.length - 1);
    }
    final words = ftsOptionWords(value);
    if (words.isEmpty) {
      throw const SqlException('no such tokenizer: ');
    }
    final key = asciiLower(words.first);
    if (key != 'simple' && key != 'ascii' && key != 'unicode61') {
      throw SqlException('no such tokenizer: ${words.first}');
    }
    return ftsTokenizer(words.first, words.sublist(1));
  }
  return AsciiTokenizer();
}

final class _Fts3Cursor extends VirtualTableCursor {
  _Fts3Cursor(this.module);
  final Fts3Module module;
  var _closed = false;
  var _index = 0;
  List<(BigInt, List<Object?>)> _rows = const [];

  @override
  void filter(String table, List<String> arguments) {
    final columns = _fts3Columns(arguments);
    final tokenizer = _fts3Tokenizer(arguments);
    final content = SearchSnapshot.current.table('${table}_content');
    final documents = <BigInt, FtsDocument>{};
    if (content != null) {
      for (final row in content.rows) {
        final texts = [
          for (var i = 0; i < columns.length; i++)
            _text(row.values.length > i + 1 ? row.values[i + 1] : null)
        ];
        documents[row.rowId] = FtsDocument(
            row.rowId,
            texts,
            [
              for (final text in texts)
                text == null ? const <FtsToken>[] : tokenizer.tokenize(text)
            ],
            List<bool>.filled(columns.length, false));
      }
    }
    final spec = Fts5Spec(
        table: table,
        columns: [for (final name in columns) Fts5Column(name)],
        tokenizer: tokenizer,
        prefix: const [],
        contentMode: 'normal',
        contentTable: null,
        contentRowid: 'docid',
        contentlessDelete: false,
        columnSize: false);
    final state = FtsTableState(spec, documents);
    final scan = module.scans[asciiLower(table)];
    final pending = _pendingQuery(scan?.$1, scan?.$2 ?? const [], spec);
    if (pending != null) {
      state.query = parseFtsQuery(pending.$1, tokenizer, columns);
      state.column = pending.$2;
    }
    ftsSession().tables[asciiLower(table)] = state;
    _rows = [
      for (final document in documents.values)
        (
          document.rowId,
          [
            for (final text in document.texts) text,
            null,
          ]
        )
    ];
    _index = 0;
  }

  @override
  void next() {
    if (_index < _rows.length) _index++;
  }

  @override
  bool get eof => _closed || _index >= _rows.length;
  @override
  Object? column(int index) => _rows[_index].$2[index];
  @override
  BigInt get rowid => _rows[_index].$1;
  @override
  void close() {
    _closed = true;
  }
}

final class RtreeColumn {
  RtreeColumn(this.name, {this.auxiliary = false});
  final String name;
  final bool auxiliary;
}

final class RtreeSpec {
  RtreeSpec(this.table, this.columns, {this.geopoly = false});
  final String table;
  final List<RtreeColumn> columns;
  final bool geopoly;
  List<String> get names => [for (final column in columns) column.name];
  int get coordinates =>
      columns.where((column) => !column.auxiliary).length - (geopoly ? 0 : 1);
  static RtreeSpec parse(String table, List<String> arguments,
      {bool geopoly = false}) {
    if (geopoly) {
      final columns = <RtreeColumn>[RtreeColumn('_shape')];
      for (final raw in arguments) {
        final name = raw.trim();
        if (name.isEmpty || name.startsWith('+')) {
          throw const SqlException('geopoly column name is invalid');
        }
        columns.add(RtreeColumn(_unquote(name)));
      }
      return RtreeSpec(table, columns, geopoly: true);
    }
    if (arguments.isEmpty) {
      throw const SqlException('Too few columns for an rtree table');
    }
    final columns = <RtreeColumn>[];
    var auxiliary = false;
    for (final raw in arguments) {
      final text = raw.trim();
      final aux = text.startsWith('+');
      if (aux) auxiliary = true;
      if (!aux && auxiliary) {
        throw const SqlException('Auxiliary rtree columns must be last');
      }
      final name = _unquote(aux ? text.substring(1).trim() : text);
      if (name.isEmpty) {
        throw const SqlException('Wrong number of columns for an rtree table');
      }
      columns.add(RtreeColumn(name, auxiliary: aux));
    }
    final coordinates = columns.where((column) => !column.auxiliary).length - 1;
    if (coordinates < 2 || coordinates.isOdd) {
      throw SqlException(coordinates < 2
          ? 'Too few columns for an rtree table'
          : 'Wrong number of columns for an rtree table');
    }
    if (coordinates > 10) {
      throw const SqlException('Too many columns for an rtree table');
    }
    return RtreeSpec(table, columns);
  }
}

String _unquote(String text) {
  if (text.length >= 2 &&
      (text.startsWith("'") || text.startsWith('"')) &&
      text.endsWith(text[0])) {
    return text.substring(1, text.length - 1);
  }
  return text;
}

final class RtreeModule extends VirtualTableModule {
  @override
  String get name => 'rtree';
  @override
  List<String> get columns => const ['id', 'minX', 'maxX'];
  @override
  void xCreate(String table, List<String> arguments) {
    RtreeSpec.parse(table, arguments);
  }

  @override
  List<String> columnsFor(String table, List<String> arguments) =>
      RtreeSpec.parse(table, arguments).names;
  @override
  List<String> shadowNames(String table, List<String> arguments) =>
      ['${table}_node', '${table}_parent', '${table}_rowid'];
  @override
  VirtualTableCursor xOpen(String table) => _RtreeCursor();
}

final class GeopolyModule extends VirtualTableModule {
  @override
  String get name => 'geopoly';
  @override
  List<String> get columns => const ['_shape'];
  @override
  void xCreate(String table, List<String> arguments) {
    RtreeSpec.parse(table, arguments, geopoly: true);
  }

  @override
  List<String> columnsFor(String table, List<String> arguments) =>
      RtreeSpec.parse(table, arguments, geopoly: true).names;
  @override
  List<String> shadowNames(String table, List<String> arguments) =>
      ['${table}_node', '${table}_parent', '${table}_rowid'];
  @override
  VirtualTableCursor xOpen(String table) => _GeopolyCursor();
}

final class RtreeCell {
  RtreeCell(this.rowId, this.coords);
  final int rowId;
  final List<double> coords;
}

List<RtreeCell> decodeRtreeNode(Uint8List bytes, int coordinates) {
  if (bytes.length < 4) return const [];
  final data = ByteData.sublistView(bytes);
  final depth = data.getInt16(0);
  final count = data.getUint16(2);
  if (depth < 0 || count < 0) {
    throw const SqlException('Invalid rtree node');
  }
  final cells = <RtreeCell>[];
  var offset = 4;
  final width = 8 + coordinates * 4;
  for (var i = 0; i < count; i++) {
    if (offset + width > bytes.length) break;
    final rowId = data.getInt64(offset);
    offset += 8;
    final coords = <double>[
      for (var c = 0; c < coordinates; c++) data.getFloat32(offset + c * 4)
    ];
    offset += coordinates * 4;
    cells.add(RtreeCell(rowId, coords));
  }
  return cells;
}

int rtreeNodeSize(int pageSize, int coordinates) {
  final cell = 8 + coordinates * 4;
  final size = pageSize - 64 < 4 + cell * 51 ? pageSize - 64 : 4 + cell * 51;
  return size < 448 ? 448 : size;
}

Uint8List encodeRtreeNode(int depth, List<RtreeCell> cells, int nodeSize) {
  final bytes = Uint8List(nodeSize);
  final data = ByteData.sublistView(bytes);
  data.setInt16(0, depth);
  data.setUint16(2, cells.length);
  var offset = 4;
  for (final cell in cells) {
    data.setInt64(offset, cell.rowId);
    offset += 8;
    for (final coord in cell.coords) {
      data.setFloat32(offset, coord);
      offset += 4;
    }
  }
  return bytes;
}

Map<int, Uint8List> _nodes(SearchSnapshot snapshot, String table) {
  final node = snapshot.table('${table}_node');
  final nodes = <int, Uint8List>{};
  if (node == null) return nodes;
  for (final row in node.rows) {
    final data = row.values.length > 1 ? row.values[1] : null;
    if (data is Uint8List) nodes[row.rowId.toInt()] = data;
  }
  return nodes;
}

List<RtreeCell> rtreeLeaves(
    SearchSnapshot snapshot, String table, int coordinates) {
  final nodes = _nodes(snapshot, table);
  final root = nodes[1];
  if (root == null || root.length < 4) return const [];
  final depth = ByteData.sublistView(root).getInt16(0);
  List<RtreeCell> walk(int nodeno, int level) {
    final bytes = nodes[nodeno];
    if (bytes == null) return const [];
    final cells = decodeRtreeNode(bytes, coordinates);
    if (level == 0) return cells;
    return [for (final cell in cells) ...walk(cell.rowId, level - 1)];
  }

  return walk(1, depth);
}

final class _RtreeCursor extends VirtualTableCursor {
  var _closed = false;
  var _index = 0;
  List<(BigInt, List<Object?>)> _rows = const [];

  @override
  void filter(String table, List<String> arguments) {
    final spec = RtreeSpec.parse(table, arguments);
    final coordinates = spec.coordinates;
    final cells = rtreeLeaves(SearchSnapshot.current, table, coordinates);
    final rowids = SearchSnapshot.current.table('${table}_rowid');
    final aux = <BigInt, List<Object?>>{};
    if (rowids != null) {
      final auxCount = spec.columns.where((column) => column.auxiliary).length;
      for (final row in rowids.rows) {
        aux[row.rowId] = [
          for (var i = 0; i < auxCount; i++)
            row.values.length > i + 2 ? row.values[i + 2] : null
        ];
      }
    }
    _rows = [
      for (final cell in cells)
        (
          BigInt.from(cell.rowId),
          [
            BigInt.from(cell.rowId),
            ...cell.coords,
            ...aux[BigInt.from(cell.rowId)] ??
                List<Object?>.filled(
                    spec.columns.where((column) => column.auxiliary).length,
                    null)
          ]
        )
    ];
    _index = 0;
  }

  @override
  void next() {
    if (_index < _rows.length) _index++;
  }

  @override
  bool get eof => _closed || _index >= _rows.length;
  @override
  Object? column(int index) => _rows[_index].$2[index];
  @override
  BigInt get rowid => _rows[_index].$1;
  @override
  void close() {
    _closed = true;
  }
}

final class _GeopolyCursor extends VirtualTableCursor {
  var _closed = false;
  var _index = 0;
  List<(BigInt, List<Object?>)> _rows = const [];

  @override
  void filter(String table, List<String> arguments) {
    final spec = RtreeSpec.parse(table, arguments, geopoly: true);
    final rowids = SearchSnapshot.current.table('${table}_rowid');
    _rows = [
      if (rowids != null)
        for (final row in rowids.rows)
          (
            row.rowId,
            [
              for (var i = 0; i < spec.columns.length; i++)
                row.values.length > i + 2 ? row.values[i + 2] : null
            ]
          )
    ];
    _index = 0;
  }

  @override
  void next() {
    if (_index < _rows.length) _index++;
  }

  @override
  bool get eof => _closed || _index >= _rows.length;
  @override
  Object? column(int index) => _rows[_index].$2[index];
  @override
  BigInt get rowid => _rows[_index].$1;
  @override
  void close() {
    _closed = true;
  }
}
