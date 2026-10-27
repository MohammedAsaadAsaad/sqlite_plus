import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

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

void main() {
  test('ORM save and filter reopen through the simulated browser store',
      () async {
    final mapping = _NoteMapping();
    final body = MappedField(mapping.body);
    final store = MemoryBrowserByteStore();
    final opened =
        await openBrowserStorage(name: 'notes', probe: () async => store);
    expect(opened.capabilities.durabilityPromised, isFalse);
    expect(opened.capabilities.placement, StoragePlacement.browser);
    final context = DbContext(
        await BrowserDatabaseConnection.open(opened), DbModel([mapping.type]));
    await context.migrations.ensureCreated();
    context.set(mapping.type).add(_Note(BigInt.one, 'kept'));
    context.set(mapping.type).add(_Note(BigInt.two, 'other'));
    expect(await context.saveChanges(), 2);
    final beforeClose = await context
        .set(mapping.type)
        .query
        .where(body.equalTo('kept'))
        .toList();
    expect(beforeClose.map((note) => note.id), [BigInt.one]);
    await context.close();

    final reopened =
        await openBrowserStorage(name: 'notes', probe: () async => store);
    expect(reopened.capabilities.canRead, isTrue);
    expect(reopened.capabilities.canWrite, isTrue);
    expect(reopened.capabilities.durabilityPromised, isFalse);
    final context2 = DbContext(await BrowserDatabaseConnection.open(reopened),
        DbModel([mapping.type]));
    final after = await context2
        .set(mapping.type)
        .query
        .where(body.equalTo('kept'))
        .toList();
    expect(after.map((note) => note.body), ['kept']);
    await context2.close();
  });

  test('a missing browser interface does not keep the ORM row', () async {
    final mapping = _NoteMapping();
    final opened =
        await openBrowserStorage(name: 'notes', probe: () async => null);
    expect(opened.capabilities.placement, StoragePlacement.memory);
    final context = DbContext(
        await BrowserDatabaseConnection.open(opened), DbModel([mapping.type]));
    await context.migrations.ensureCreated();
    context.set(mapping.type).add(_Note(BigInt.one, 'gone'));
    expect(await context.saveChanges(), 1);
    await context.close();

    final again =
        await openBrowserStorage(name: 'notes', probe: () async => null);
    expect(await again.storage.length(), 0);
    expect(again.capabilities.durabilityPromised, isFalse);
    await again.storage.close();
  });
}
