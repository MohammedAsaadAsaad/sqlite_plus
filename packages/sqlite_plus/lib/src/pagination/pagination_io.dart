import '../connection/database_owner.dart';
import 'pagination.dart';

/// Cursor pages through the same serialized file-owner client/transaction.
extension DatabaseClientPagination on DatabaseClient {
  Future<SqlPage<Map<String, Object?>>> page(
          {required String table,
          required List<String> keyColumns,
          List<PageOrder> orderBy = const [],
          List<String>? columns,
          String? where,
          List<Object?> parameters = const [],
          int size = 30,
          PageCursor? after,
          PageCursor? before,
          String cursorScope = ''}) =>
      SqlPagination((sql, args) => query(sql, args)).page(
          table: table,
          keyColumns: keyColumns,
          orderBy: orderBy,
          columns: columns,
          where: where,
          parameters: parameters,
          size: size,
          after: after,
          before: before,
          cursorScope: cursorScope);
}

/// Pages on the owner returned by openDatabase, preserving its client identity.
extension DatabaseOwnerPagination on DatabaseOwner {
  Future<SqlPage<Map<String, Object?>>> page(
          {required String table,
          required List<String> keyColumns,
          List<PageOrder> orderBy = const [],
          List<String>? columns,
          String? where,
          List<Object?> parameters = const [],
          int size = 30,
          PageCursor? after,
          PageCursor? before,
          String cursorScope = ''}) =>
      client.page(
          table: table,
          keyColumns: keyColumns,
          orderBy: orderBy,
          columns: columns,
          where: where,
          parameters: parameters,
          size: size,
          after: after,
          before: before,
          cursorScope: cursorScope);
}
