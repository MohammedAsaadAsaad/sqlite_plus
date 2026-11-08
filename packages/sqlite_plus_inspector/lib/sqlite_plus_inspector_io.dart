/// Explicit IO adapters; import the browser-safe core entry point on Web.
library;

import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus/sqlite_plus.dart' show QueryResult, MutationResult;
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'sqlite_plus_inspector_orm.dart';
export 'sqlite_plus_inspector.dart';

extension SqlInspectorFile on SqlInspector {
  /// Query/execute use raw SQL. Source calls made on owner/client bypass this.
  InspectedConnection file(DatabaseOwner owner, {String label = 'file'}) =>
      InspectedConnection(
          inspector: this,
          query: owner.client.query,
          execute: owner.client.execute,
          close: owner.close,
          inTransaction: () => owner.client.inTransaction,
          label: label);

  /// Closing the wrapper closes this logical client, not its file owner.
  InspectedConnection client(DatabaseClient client,
          {String label = 'client'}) =>
      InspectedConnection(
          inspector: this,
          query: client.query,
          execute: client.execute,
          close: () async => client.close(),
          inTransaction: () => client.inTransaction,
          label: label);
}

/// Optional file owner to ORM bridge; closing its context closes this owner.
final class InspectorFileOrmConnection extends OrmConnection {
  InspectorFileOrmConnection(this.fileOwner);
  final DatabaseOwner fileOwner;
  static final _leases = Expando<InspectorFileOrmConnection>();
  bool _claimed = false;
  @override
  void claim(Object owner) {
    final lease = _leases[fileOwner];
    if (!fileOwner.isOpen || lease != null && !identical(lease, this)) {
      throw const OrmStateException(
          'File owner is closed or belongs to another ORM connection');
    }
    super.claim(owner);
    _claimed = true;
    _leases[fileOwner] = this;
  }

  @override
  void release(Object owner) {
    super.release(owner);
    _claimed = false;
    if (identical(_leases[fileOwner], this)) _leases[fileOwner] = null;
  }

  @override
  bool get inTransaction => fileOwner.client.inTransaction;
  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      fileOwner.client.query(sql, parameters);
  @override
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      fileOwner.client.execute(sql, parameters);
  @override
  Future<void> close() {
    if (_claimed) {
      return Future.error(const OrmStateException(
          'Release the owner before closing its connection'));
    }
    return fileOwner.close();
  }
}

extension SqlInspectorFileOrm on SqlInspector {
  InspectedOrmConnection ormFile(DatabaseOwner owner,
          {String label = 'orm-file'}) =>
      ormConnection(InspectorFileOrmConnection(owner), label: label);
}
