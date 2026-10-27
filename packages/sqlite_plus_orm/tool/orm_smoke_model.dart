import 'dart:typed_data';

import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

const peopleTable = 'people "主"';
const ordersTable = 'order';

final class SmokePerson {
  SmokePerson(this.name,
      {this.id,
      this.active = true,
      DateTime? created,
      this.avatar,
      BigInt? revision,
      this.note})
      : created = created ?? DateTime.utc(2026, 10, 26, 12, 34, 56, 789, 123),
        revision = revision ?? BigInt.one;
  BigInt? id;
  String name;
  bool active;
  DateTime created;
  Uint8List? avatar;
  BigInt revision;
  String? note;
}

final class SmokeOrder {
  SmokeOrder(this.description, {this.id, BigInt? personId, this.quantity = 1})
      : personId = personId ?? BigInt.zero;
  BigInt? id;
  BigInt personId;
  String description;
  int quantity;
}

final class SmokeModel {
  SmokeModel({this.withNote = false}) {
    personId = Column(
        property: 'id',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (SmokePerson person) => person.id,
        write: (person, value) => person.id = value,
        keyOrder: 0,
        generated: true);
    name = Column(
        property: 'name',
        name: 'display name',
        codec: Codecs.text,
        read: (SmokePerson person) => person.name,
        write: (person, value) => person.name = value,
        unique: true);
    active = Column(
        property: 'active',
        codec: Codecs.boolean,
        read: (SmokePerson person) => person.active,
        write: (person, value) => person.active = value);
    created = Column(
        property: 'created',
        codec: Codecs.dateTime,
        read: (SmokePerson person) => person.created,
        write: (person, value) => person.created = value);
    avatar = Column(
        property: 'avatar',
        codec: Codecs.nullable(Codecs.blob),
        read: (SmokePerson person) => person.avatar,
        write: (person, value) => person.avatar = value);
    revision = Column(
        property: 'revision',
        codec: Codecs.bigInt,
        read: (SmokePerson person) => person.revision,
        write: (person, value) => person.revision = value,
        version: true);
    note = Column(
        property: 'note',
        codec: Codecs.nullable(Codecs.text),
        read: (SmokePerson person) => person.note,
        write: (person, value) => person.note = value);
    people = EntityType<SmokePerson>(
        tableName: peopleTable,
        columns: [
          personId,
          name,
          active,
          created,
          avatar,
          revision,
          if (withNote) note
        ],
        indexes: [
          OrmIndex(name: 'people_created', columns: [created])
        ],
        create: (row) => SmokePerson(row.read(name),
            id: row.read(personId),
            active: row.read(active),
            created: row.read(created),
            avatar: row.read(avatar),
            revision: row.read(revision),
            note: withNote ? row.read(note) : null));
    orderId = Column(
        property: 'id',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (SmokeOrder order) => order.id,
        write: (order, value) => order.id = value,
        keyOrder: 0,
        generated: true);
    orderPerson = Column(
        property: 'personId',
        codec: Codecs.bigInt,
        read: (SmokeOrder order) => order.personId,
        write: (order, value) => order.personId = value);
    description = Column(
        property: 'description',
        codec: Codecs.text,
        read: (SmokeOrder order) => order.description,
        write: (order, value) => order.description = value);
    quantity = Column(
        property: 'quantity',
        codec: Codecs.integer,
        read: (SmokeOrder order) => order.quantity,
        write: (order, value) => order.quantity = value);
    orders = EntityType<SmokeOrder>(
        tableName: ordersTable,
        columns: [orderId, orderPerson, description, quantity],
        create: (row) => SmokeOrder(row.read(description),
            id: row.read(orderId),
            personId: row.read(orderPerson),
            quantity: row.read(quantity)));
    orderOwner = ForeignKey<SmokeOrder, SmokePerson>(
        name: 'owner',
        child: orders,
        parent: people,
        columns: [orderPerson],
        targetColumns: [personId],
        onDelete: ForeignKeyAction.cascade);
    model = DbModel([people, orders], foreignKeys: [orderOwner]);
  }
  final bool withNote;
  late final Column<SmokePerson, BigInt?> personId;
  late final Column<SmokePerson, String> name;
  late final Column<SmokePerson, bool> active;
  late final Column<SmokePerson, DateTime> created;
  late final Column<SmokePerson, Uint8List?> avatar;
  late final Column<SmokePerson, BigInt> revision;
  late final Column<SmokePerson, String?> note;
  late final Column<SmokeOrder, BigInt?> orderId;
  late final Column<SmokeOrder, BigInt> orderPerson;
  late final Column<SmokeOrder, String> description;
  late final Column<SmokeOrder, int> quantity;
  late final EntityType<SmokePerson> people;
  late final EntityType<SmokeOrder> orders;
  late final ForeignKey<SmokeOrder, SmokePerson> orderOwner;
  late final DbModel model;
}
