import 'dart:js_interop';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// Chrome entry. The runner serves this compiled script and records the
/// posted text. A passing run is one page session, not a power-loss proof.
@JS('fetch')
external JSPromise<JSAny?> _fetch(JSString resource, _RequestInit init);

extension type _RequestInit._(JSObject _) implements JSObject {
  external factory _RequestInit({String method, String body});
}

@JS('document.getElementById')
external JSObject? _element(JSString id);

extension type _Element(JSObject _) implements JSObject {
  external set textContent(String? value);
}

final class _Note {
  _Note(this.id, this.body);
  final BigInt id;
  final String body;
}

final class _NoteMapping {
  _NoteMapping() {
    id = Column(
        property: 'id',
        name: 'id',
        codec: Codecs.bigInt,
        read: (note) => note.id,
        keyOrder: 0);
    body = Column(
        property: 'body',
        name: 'body',
        codec: Codecs.text,
        read: (note) => note.body);
    type = EntityType(
        tableName: 'notes',
        columns: [id, body],
        create: (row) => _Note(row.read(id), row.read(body)));
  }

  late final Column<_Note, BigInt> id;
  late final Column<_Note, String> body;
  late final EntityType<_Note> type;
}

Future<void> _publish(String text) async {
  final node = _element('result'.toJS);
  if (node != null) _Element(node).textContent = text;
  await _fetch('/result'.toJS, _RequestInit(method: 'POST', body: text)).toDart;
}

Future<void> main() async {
  final lines = <String>[];
  try {
    final mapping = _NoteMapping();
    final body = MappedField(mapping.body);
    final opened = await openBrowserStorage(name: 'chrome-notes');
    lines.add('placement=${opened.capabilities.placement.name}');
    lines.add('canRead=${opened.capabilities.canRead}');
    lines.add('canWrite=${opened.capabilities.canWrite}');
    lines.add('durabilityPromised=${opened.capabilities.durabilityPromised}');
    if (opened.capabilities.placement != StoragePlacement.browser) {
      throw StateError('Chrome did not expose OPFS or IndexedDB');
    }
    if (opened.capabilities.durabilityPromised) {
      throw StateError('Browser storage promised power-loss durability');
    }
    final context = DbContext(
        await BrowserDatabaseConnection.open(opened), DbModel([mapping.type]));
    await context.migrations.ensureCreated();
    context.set(mapping.type).add(_Note(BigInt.one, 'kept'));
    context.set(mapping.type).add(_Note(BigInt.two, 'other'));
    final saved = await context.saveChanges();
    lines.add('saved=$saved');
    final before = await context
        .set(mapping.type)
        .query
        .where(body.equalTo('kept'))
        .toList();
    lines.add('before=${before.map((note) => note.body).join(',')}');
    await context.close();

    final reopened = await openBrowserStorage(name: 'chrome-notes');
    lines.add('reopenPlacement=${reopened.capabilities.placement.name}');
    lines.add(
        'reopenDurabilityPromised=${reopened.capabilities.durabilityPromised}');
    final context2 = DbContext(await BrowserDatabaseConnection.open(reopened),
        DbModel([mapping.type]));
    final after = await context2
        .set(mapping.type)
        .query
        .where(body.equalTo('kept'))
        .toList();
    lines.add('reopenBody=${after.map((note) => note.body).join(',')}');
    await context2.close();
    if (before.map((note) => note.body).join(',') != 'kept' ||
        after.map((note) => note.body).join(',') != 'kept' ||
        saved != 2) {
      throw StateError('ORM filter did not return the saved note');
    }
    lines.add('result=pass');
  } catch (error, stack) {
    lines.add('result=fail');
    lines.add('$error');
    lines.add('$stack');
  }
  await _publish(lines.join('\n'));
}
