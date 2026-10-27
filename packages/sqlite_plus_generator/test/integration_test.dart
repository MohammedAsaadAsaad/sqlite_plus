import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('generated consumers migrate, track CRUD and relationships, then reopen',
      () async {
    final fixture = await Consumer.create(modelSource('''
class Customer {
  Customer({this.id, required this.name, this.revision = 0});
  final BigInt? id;
  final String name;
  @DbVersion()
  final int revision;
}
class Purchase {
  Purchase({this.id, this.customerId, required this.total});
  BigInt? id;
  BigInt? customerId;
  double total;
}
class Assigned {
  Assigned(this.id, this.value);
  String? id;
  String value;
}
'''));
    addTearDown(fixture.close);
    await writeGenerated(await generateLibrary(fixture.input));
    final run = await fixture.run(r'''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final database = await MutableSqliteDatabase.create();
  final context = DbContext(MutableDatabaseConnection(database), generatedModel);
  await context.migrations.ensureCreated();
  check((await context.migrations.plan()).isEmpty, 'stable migration');
  final customers = context.set(CustomerMapping.instance);
  final purchases = context.set(PurchaseMapping.instance);
  final assigned = context.set(AssignedMapping.instance);
  final original = Customer(name: 'Ada');
  final customer = customers.add(original);
  final purchase = purchases.add(Purchase(total: 12.5));
  purchase.reference(PurchaseRelationships.customer).set(customer);
  int inserted;
  try { inserted = await context.saveChanges(); }
  on OrmException catch (error) {
    throw StateError('save: $error; cause: ${error.cause}');
  }
  check(inserted == 2, 'insert count');
  final id = customer.entity.id!;
  check(id > BigInt.zero && original.id == null, 'immutable generated id');
  check(purchase.entity.customerId == id, 'linked generated key');
  check(customer.state == EntityState.unchanged, 'saved snapshot');
  final revision = customer.entity.revision;
  customers.replace(customer.entity,
      Customer(id: id, name: 'Grace', revision: revision));
  check(await context.saveChanges() == 1, 'immutable update');
  check(customer.entity.revision == revision + 1, 'version refresh');
  purchase.entity.total = 22.5;
  check(purchase.state == EntityState.modified, 'mutable change tracking');
  check(await context.saveChanges() == 1, 'mutable update');
  check(identical(await purchase.reference(PurchaseRelationships.customer).load(),
      customer.entity), 'reference identity');
  check((await customer.collection(PurchaseRelationships.customer).load()).single ==
      purchase.entity, 'collection loading');
  check((await purchases.query.where(PurchaseColumns.total.gt(20.0)).toList()).single ==
      purchase.entity, 'typed query');
  check((await purchases.query.filter((row) => row.total > 20.0).orderByFields((row) => [row.total.ascending]).toList()).single ==
      purchase.entity, 'dart field filter');
  assigned.add(Assigned('assigned-key', 'kept'));
  check(await context.saveChanges() == 1, 'nullable assigned key');
  var refusedNull = false;
  try { assigned.add(Assigned(null, 'invalid')); }
  on OrmStateException { refusedNull = true; }
  check(refusedNull, 'assigned key requires a value');
  await context.close();
  final image = database.exportImage();
  await database.close();

  final reopened = await MutableSqliteDatabase.fromImage(image);
  final next = DbContext(MutableDatabaseConnection(reopened), generatedModel);
  await next.migrations.ensureCreated();
  final storedCustomer = (await next.set(CustomerMapping.instance)
      .find(CustomerMapping.key(id)))!;
  final storedPurchase = (await next.set(PurchaseMapping.instance).query.toList()).single;
  check(storedCustomer.name == 'Grace' && storedPurchase.total == 22.5, 'reopen values');
  check((await next.entry(storedPurchase).reference(PurchaseRelationships.customer).load()) ==
      storedCustomer, 'reopen relationship');
  check((await next.set(AssignedMapping.instance).find(AssignedMapping.key('assigned-key')))!
      .value == 'kept', 'assigned key reopen');
  next.set(PurchaseMapping.instance).remove(storedPurchase);
  next.set(CustomerMapping.instance).remove(storedCustomer);
  check(await next.saveChanges() == 2, 'ordered deletion');
  check(await next.set(CustomerMapping.instance).query.count() == BigInt.zero, 'deleted rows');
  await next.close();
  await reopened.close();
  print('generated ORM integration passed');
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(normalizeNewlines(run.stdout), 'generated ORM integration passed\n');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
