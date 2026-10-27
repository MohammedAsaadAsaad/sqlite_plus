@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:sqlite_plus_generator/sqlite_plus_generator.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Future<Consumer> consumer(String body, {String? import}) async {
    final result = await Consumer.create(
        import == null ? modelSource(body) : modelSource(body, import: import));
    addTearDown(result.close);
    return result;
  }

  test('example output is a deterministic golden', () async {
    final fixture =
        await Consumer.create(await File('example/models.dart').readAsString());
    addTearDown(fixture.close);
    final result = await generateLibrary(fixture.input);
    expect(result.code, await File('example/models.orm.g.dart').readAsString());
    await writeGenerated(result);
    expect((await generateLibrary(fixture.input)).code, result.code);
  });

  test(
      'conventions generate typed keys, mutable/immutable rows and relationships',
      () async {
    final fixture = await consumer('''
typedef UserId = BigInt;
class Customer {
  Customer({this.id, required this.name});
  UserId? id;
  String name;
}
class Purchase {
  Purchase({required this.id, required this.customerId, required this.total});
  final BigInt id;
  BigInt customerId;
  double total;
}
''');
    final first = await generateLibrary(fixture.input);
    expect(first.entityNames, ['Customer', 'Purchase']);
    expect(File(fixture.output).existsSync(), isFalse);
    expect(await writeGenerated(first, check: true), isFalse);
    expect(await writeGenerated(first), isTrue);
    final second = await generateLibrary(fixture.input);
    expect(second.code, first.code);
    expect(await writeGenerated(second, check: true), isTrue);
    final analyzed = await fixture.analyze();
    expect(analyzed.exitCode, 0,
        reason: '${analyzed.stdout}\n${analyzed.stderr}');
    final run = await fixture.run('''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
void main() {
  if (generatedModel.entities.length != 2) throw StateError('models');
  if (CustomerMapping.instance.generatedKey != CustomerColumns.id) throw StateError('key');
  final person = CustomerMapping.instance.create(RowReader({'id': BigInt.one, 'name': 'Ada'}));
  if (person.id != BigInt.one || person.name != 'Ada') throw StateError('row');
  CustomerColumns.name.write!(person, 'Grace');
  if (person.name != 'Grace') throw StateError('setter');
  if (CustomerMapping.key(BigInt.one) != EntityKey([BigInt.one])) throw StateError('typed key');
  if (PurchaseColumns.id.write != null || PurchaseMapping.instance.applyStoreValues == null) {
    throw StateError('immutable');
  }
  if (generatedModel.foreignKeys.single != PurchaseRelationships.customer) throw StateError('FK');
  print('generated metadata works');
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout, 'generated metadata works\n');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'prefixed annotations preserve quoted names, composites and immutable state',
      () async {
    final fixture = await consumer(r'''
@orm.DbEntity(table: r'quoted"$table')
class Label {
  Label.named({required this.code, required this.region, required this.revision, this.note});
  @orm.DbKey(order: 0)
  final String code;
  @orm.DbKey(order: 1)
  final String region;
  @orm.DbVersion()
  BigInt revision;
  @orm.DbColumn(name: r'display"$name', unique: true, defaultSql: r"'a$b'")
  String? note;
  @orm.DbIgnore()
  int transient = 4;
}
''', import: "import 'package:sqlite_plus_orm/sqlite_plus_orm.dart' as orm;");
    final result = await generateLibrary(fixture.input);
    expect(result.code, contains(r'\$table'));
    expect(result.code, contains('orm.EntityType<Label>'));
    await writeGenerated(result);
    final run = await fixture.run(r'''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
void main() {
  if (LabelMapping.instance.tableName != r'quoted"$table') throw StateError('table');
  if (LabelColumns.note.sqlName != r'display"$name') throw StateError('column');
  if (LabelMapping.instance.keys.length != 2 || LabelColumns.note.defaultSql != r"'a$b'") {
    throw StateError('metadata');
  }
  final item = LabelMapping.instance.create(RowReader({
    'code': 'C', 'region': 'EU', 'revision': BigInt.one, r'display"$name': 'note'
  }));
  if (item.code != 'C' || item.region != 'EU' || item.transient != 4) throw StateError('constructor');
  print('annotations work');
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('all builtin codecs and nullable fields compile and materialize',
      () async {
    final fixture = await consumer('''
class Scalars {
  Scalars({required this.id, required this.i, required this.real,
    required this.flag, required this.text, required this.bytes, required this.time,
    this.optionalInteger, this.optionalReal, this.optionalFlag, this.optionalText,
    this.optionalBytes, this.optionalTime});
  BigInt id;
  int i;
  double real;
  bool flag;
  String text;
  Uint8List bytes;
  DateTime time;
  int? optionalInteger;
  double? optionalReal;
  bool? optionalFlag;
  String? optionalText;
  Uint8List? optionalBytes;
  DateTime? optionalTime;
}
''',
        import:
            "import 'dart:typed_data';\nimport 'package:sqlite_plus_orm/sqlite_plus_orm.dart';");
    await writeGenerated(await generateLibrary(fixture.input));
    final run = await fixture.run('''
import 'dart:typed_data';
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
void main() {
  final bytes = Uint8List.fromList([1,2]);
  final item = ScalarsMapping.instance.create(RowReader({
    'id': BigInt.one, 'i': BigInt.two, 'real': 3.5, 'flag': BigInt.one,
    'text': 'text', 'bytes': bytes, 'time': '2024-01-02T03:04:05.000Z',
    'optionalInteger': null, 'optionalReal': null, 'optionalFlag': null,
    'optionalText': null, 'optionalBytes': null, 'optionalTime': null
  }));
  if (item.i != 2 || !item.flag || item.time.isUtc != true || item.optionalInteger != null) {
    throw StateError('scalar decode');
  }
  item.bytes[0] = 9;
  if (bytes[0] != 1) throw StateError('blob ownership');
  print('codecs work');
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('classId conventions, inferred fields and prefixed scalar types compile',
      () async {
    final fixture = await consumer('''
typedef Identity = core.BigInt;
class Customer {
  Customer(this.customerId, this.bytes);
  final Identity customerId;
  data.Uint8List? bytes;
  var name = 'inferred';
}
''',
        import: "import 'dart:core' as core;\n"
            "import 'dart:typed_data' as data;\n"
            "import 'package:sqlite_plus_orm/sqlite_plus_orm.dart' as orm;");
    final generated = await generateLibrary(fixture.input);
    expect(generated.code, contains('data.Uint8List?'));
    expect(generated.code, contains('core.String'));
    await writeGenerated(generated);
    final analyzed = await fixture.analyze();
    expect(analyzed.exitCode, 0,
        reason: '${analyzed.stdout}\n${analyzed.stderr}');
    final run = await fixture.run('''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
void main() {
  final value = CustomerMapping.instance.create(RowReader({
    'customerId': BigInt.zero, 'bytes': null, 'name': 'stored'
  }));
  if (value.customerId != BigInt.zero || value.name != 'stored' ||
      CustomerColumns.customerId.generated) throw StateError('mapping');
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('constructor assignments and nullable aliases preserve stored values',
      () async {
    final fixture = await consumer('''
typedef OptionalKey = int?;
class Mutable {
  Mutable(this.id, String name);
  OptionalKey id;
  String name = 'initial';
}
class Immutable {
  Immutable(int id, String name): id = id, name = name;
  final int id;
  final String name;
}
class HashCode { HashCode(this.id); int id; }
class Child { Child(this.id,this.hashCodeId); int id; int hashCodeId; }
''');
    final result = await generateLibrary(fixture.input);
    expect(result.code, contains('EntityKey key(int value0)'));
    expect(result.code, contains('ForeignKey<Child, HashCode> hashCodeId'));
    await writeGenerated(result);
    final analyzed = await fixture.analyze();
    expect(analyzed.exitCode, 0,
        reason: '${analyzed.stdout}\n${analyzed.stderr}');
    final run = await fixture.run('''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
void main() {
  final mutable = MutableMapping.instance.create(RowReader({'id': BigInt.zero, 'name': 'stored'}));
  final immutable = ImmutableMapping.instance.create(RowReader({'id': BigInt.one, 'name': 'stored'}));
  if (mutable.id != 0 || mutable.name != 'stored' || immutable.name != 'stored') {
    throw StateError('constructor fields');
  }
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test(
      'explicit references use actual selected target metadata and delete policy',
      () async {
    final fixture = await consumer('''
class Customer { Customer(this.id); @DbColumn(name: 'customer_key') final BigInt id; }
class Ticket {
  Ticket(this.id, this.owner);
  final String id;
  @DbReference(Customer, column: 'id', onDelete: ForeignKeyAction.setNull)
  BigInt? owner;
}
''');
    await writeGenerated(await generateLibrary(fixture.input));
    final run = await fixture.run('''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
void main() {
  final reference = generatedModel.foreignKeys.single;
  if (reference.onDelete != ForeignKeyAction.setNull || reference.columns.single != TicketColumns.owner) {
    throw StateError('reference');
  }
  print('reference works');
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test(
      'implicit constructor and optional ignored parameters map mutable storage',
      () async {
    final fixture = await consumer('''
class Mutable { BigInt? id; String name = ''; }
class Named {
  Named.load({required this.id, this.name = 'default', int ignored = 3});
  final int id;
  String name;
}
''');
    await writeGenerated(await generateLibrary(fixture.input));
    final analyzed = await fixture.analyze();
    expect(analyzed.exitCode, 0,
        reason: '${analyzed.stdout}\n${analyzed.stderr}');
    final run = await fixture.run('''
import 'package:generator_consumer/models.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
void main() {
  final a = MutableMapping.instance.create(RowReader({'id': BigInt.two, 'name': 'ready'}));
  final b = NamedMapping.instance.create(RowReader({'id': BigInt.one, 'name': 'named'}));
  if (a.name != 'ready' || b.name != 'named' || b.id != 1) throw StateError('constructors');
}
''');
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test(
      'generation resolves annotation/type identity without running model code',
      () async {
    final fixture = await consumer('''
final marker = File('SHOULD_NOT_EXIST').writeAsStringSync('executed');
class DbColumn { const DbColumn({this.name}); final String? name; }
class Customer {
  Customer(this.id, this.name);
  final BigInt id;
  @DbColumn(name: 'impostor')
  String name;
}
''',
        import:
            "import 'dart:io';\nimport 'package:sqlite_plus_orm/sqlite_plus_orm.dart';");
    final result = await generateLibrary(fixture.input);
    expect(result.code, contains('name: "name"'));
    expect(result.code, isNot(contains('impostor')));
    expect(File('SHOULD_NOT_EXIST').existsSync(), isFalse);
    expect(File('${fixture.directory.path}/SHOULD_NOT_EXIST').existsSync(),
        isFalse);
  });

  final negative = <(String, String, String)>[
    (
      'unsupported dynamic',
      '@DbEntity() class Bad { Bad(this.id,this.value); final int id; dynamic value; }',
      'G006'
    ),
    (
      'unsupported custom type',
      'class DateTime {} class Bad { Bad(this.id,this.time); final int id; DateTime time; }',
      'G006'
    ),
    (
      'unsupported enum',
      'enum Status { active } class Bad { Bad(this.id,this.status); final int id; Status status; }',
      'G006'
    ),
    (
      'unsupported collection',
      'class Bad { Bad(this.id,this.values); int id; List<String> values; }',
      'G006'
    ),
    (
      'unsupported Object',
      'class Bad { Bad(this.id,this.value); int id; Object? value; }',
      'G006'
    ),
    (
      'mixed-in model',
      'mixin Extra {} class Bad with Extra { Bad(this.id); int id; }',
      'G005'
    ),
    (
      'generated column list collision',
      'class Bad { Bad(this.id,this.all); int id; String all; }',
      'G011'
    ),
    (
      'wrong constructor parameter type',
      'class Bad { Bad(String id): id=int.parse(id); final int id; }',
      'G010'
    ),
    (
      'unproven final constructor initializer',
      'class Bad { Bad(this.id, String name): name="discarded"; int id; final String name; }',
      'G010'
    ),
    (
      'static Object member collision',
      'class Bad { Bad(this.id,this.hashCode); int id; int hashCode; }',
      'G011'
    ),
    (
      'empty default SQL',
      'class Bad { Bad(this.id,this.name); int id; @DbColumn(defaultSql: " ") String name; }',
      'G007'
    ),
    (
      'duplicate version',
      'class Bad { Bad(this.id,this.a,this.b); int id; @DbVersion() int a; @DbVersion() int b; }',
      'G009'
    ),
    (
      'duplicate table name',
      'class One { One(this.id); int id; } @DbEntity(table: "ONE") class Two { Two(this.id); int id; }',
      'G007'
    ),
    (
      'foreign key property is not its SQL name',
      'class Parent { Parent(this.id); @DbColumn(name: "pk") int id; } class Bad { Bad(this.id,this.owner); int id; @DbReference(Parent,column: "pk") int owner; }',
      'G012'
    ),
    (
      'optional positional hole',
      'class Bad { Bad(this.id,[String ignored="x",this.name="n"]); int id; String name; }',
      'G010'
    ),
    ('generic class', 'class Bad<T> { Bad(this.id); final int id; }', 'G005'),
    (
      'inherited storage',
      'class Base {} class Bad extends Base { Bad(this.id); final int id; }',
      'G005'
    ),
    (
      'missing key',
      '@DbEntity() class Bad { Bad(this.name); String name; }',
      'G008'
    ),
    (
      'ambiguous key',
      'class Bad { Bad(this.id,this.badId); int id; int badId; }',
      'G008'
    ),
    (
      'duplicate SQL name',
      'class Bad { Bad(this.id,this.value); final int id; @DbColumn(name: "ID") String value; }',
      'G007'
    ),
    (
      'invalid generated key',
      'class Bad { Bad(this.id); @DbKey(generated: true) String? id; }',
      'G009'
    ),
    (
      'bad key order',
      'class Bad { Bad(this.id); @DbKey(order: 1) int id; }',
      'G008'
    ),
    (
      'invalid version',
      'class Bad { Bad(this.id,this.version); final int id; @DbVersion() String version; }',
      'G009'
    ),
    (
      'ignored required ctor state',
      'class Bad { Bad(this.id,this.temporary); final int id; @DbIgnore() final String temporary; }',
      'G010'
    ),
    (
      'unmapped final field',
      'class Bad { Bad(this.id); final int id; final String name="fixed"; }',
      'G010'
    ),
    (
      'ambiguous constructors',
      'class Bad { Bad.a(this.id); Bad.b(this.id); final int id; }',
      'G010'
    ),
    (
      'duplicate generated identifier',
      'class Bad { Bad(this.id); final int id; } class BadMapping {}',
      'G011'
    ),
    (
      'missing FK target',
      'class Other { Other(this.code); final int code; } class Bad { Bad(this.id,this.owner); final int id; @DbReference(Other) int owner; }',
      'G012'
    ),
    (
      'incompatible FK',
      'class Parent { Parent(this.id); final int id; } class Bad { Bad(this.id,this.owner); final int id; @DbReference(Parent) String owner; }',
      'G012'
    ),
    (
      'invalid null action',
      'class Parent { Parent(this.id); final int id; } class Bad { Bad(this.id,this.owner); final int id; @DbReference(Parent,onDelete:ForeignKeyAction.setNull) int owner; }',
      'G012'
    ),
  ];
  for (final (name, source, code) in negative) {
    test('located diagnostic: $name', () async {
      final fixture = await consumer(source);
      try {
        await generateLibrary(fixture.input);
        fail('Expected $code for $name');
      } on GenerationException catch (error) {
        expect(error.diagnostics.map((diagnostic) => diagnostic.code),
            contains(code));
        expect(
            error.diagnostics.every(
                (diagnostic) => diagnostic.line > 0 && diagnostic.column > 0),
            isTrue);
        expect(error.toString(), contains(fixture.input));
      }
      expect(File(fixture.output).existsSync(), isFalse);
    });
  }

  test(
      'explicit class selection omits unrelated conventions and diagnoses missing names',
      () async {
    final fixture = await consumer('''
class One { One(this.id); final int id; }
class Two { Two(this.id); final int id; }
abstract class Abstract { int get id; }
''');
    final result = await generateLibrary(fixture.input, classNames: ['Two']);
    expect(result.entityNames, ['Two']);
    expect(result.code, isNot(contains('OneMapping')));
    await expectLater(generateLibrary(fixture.input, classNames: ['Missing']),
        throwsA(isA<GenerationException>()));
  });

  test(
      'bad source, import and part configuration produce actionable diagnostics',
      () async {
    for (final source in [
      'class One { One(this.id); final int id; }',
      "part 'models.orm.g.dart'; class One { One(this.id); final int id; }",
      modelSource('class One { One(this.id); final int id; }',
          import:
              "import 'package:sqlite_plus_orm/sqlite_plus_orm.dart' deferred as orm;"),
      modelSource('class One { One(this.id); final int id; }',
          import:
              "import 'package:sqlite_plus_orm/sqlite_plus_orm.dart' as OneMapping;"),
      modelSource('class One { broken! }')
    ]) {
      final fixture = await Consumer.create(source);
      addTearDown(fixture.close);
      await expectLater(
          generateLibrary(fixture.input), throwsA(isA<GenerationException>()));
    }
  });

  test('hand-written outputs and symbolic links are never overwritten',
      () async {
    final fixture = await consumer('class One { One(this.id); final int id; }');
    await File(fixture.output).writeAsString('// user code\n');
    await expectLater(
        generateLibrary(fixture.input), throwsA(isA<GenerationException>()));
    expect(await File(fixture.output).readAsString(), '// user code\n');
    await File(fixture.output).delete();
    await Link(fixture.output).create(fixture.input);
    await expectLater(
        generateLibrary(fixture.input), throwsA(isA<GenerationException>()));
  });

  test(
      'CLI generates, checks staleness, reports bad arguments and never writes partial output',
      () async {
    final fixture = await consumer('class One { One(this.id); final int id; }');
    final help = await fixture.cli(['--help']);
    expect(help.exitCode, 0);
    expect(help.stdout, contains('--input'));
    final missing = await fixture.cli([]);
    expect(missing.exitCode, 64);
    final generated = await fixture.cli(['--input', fixture.input]);
    expect(generated.exitCode, 0,
        reason: '${generated.stdout}\n${generated.stderr}');
    final checked = await fixture.cli(['--input', fixture.input, '--check']);
    expect(checked.exitCode, 0, reason: '${checked.stdout}\n${checked.stderr}');
    await File(fixture.input).writeAsString(
        modelSource('class One { One(this.id); final BigInt id; }'));
    final stale = await fixture.cli(['--input', fixture.input, '--check']);
    expect(stale.exitCode, 1, reason: '${stale.stdout}\n${stale.stderr}');
    final previous = await File(fixture.output).readAsString();
    await File(fixture.input).writeAsString(modelSource(
        'class One { One(this.id); final int id; } @DbEntity() class Invalid {}'));
    final invalid = await fixture.cli(['--input', fixture.input]);
    expect(invalid.exitCode, 65);
    expect(await File(fixture.output).readAsString(), previous);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
