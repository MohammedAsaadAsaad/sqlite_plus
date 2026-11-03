import 'package:flutter/material.dart';

import 'format.dart';
import 'session.dart';

/// One page of the selected table or view.
class DataPane extends StatelessWidget {
  const DataPane({
    super.key,
    required this.object,
    required this.slice,
    required this.busy,
    required this.onPrevious,
    required this.onNext,
    required this.onInsert,
    required this.onEdit,
    required this.onDelete,
    required this.onShowSql,
  });

  final SchemaObject? object;
  final TableSlice slice;
  final bool busy;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onInsert;
  final void Function(ColumnInfo column, BigInt rowid, Object? current)? onEdit;
  final void Function(BigInt rowid)? onDelete;
  final VoidCallback onShowSql;

  @override
  Widget build(BuildContext context) {
    final object = this.object;
    if (object == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Choose a table, or open SQL and create one.'),
        ),
      );
    }
    if (object.type != 'table' && object.type != 'view') {
      return Center(child: Text(object.sql ?? object.name));
    }
    final headers = slice.columns.map((column) => column.name).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${object.name}  ${slice.total} rows',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                key: const Key('show-sql'),
                tooltip: 'Create statement',
                onPressed: object.sql == null ? null : onShowSql,
                icon: const Icon(Icons.info_outline),
              ),
              IconButton(
                key: const Key('insert-row'),
                tooltip: 'Insert default row',
                onPressed: busy || object.type != 'table' ? null : onInsert,
                icon: const Icon(Icons.add),
              ),
              IconButton(
                key: const Key('page-previous'),
                tooltip: 'Previous page',
                onPressed: busy ? null : onPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                key: const Key('page-next'),
                tooltip: 'Next page',
                onPressed: busy ? null : onNext,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        if (!slice.hasRowid && object.type == 'table')
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('This table has no rowid. Change it with SQL.'),
          ),
        Expanded(
          child: slice.rows.isEmpty
              ? const Center(child: Text('This table has no rows.'))
              : Scrollbar(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: DataTable(
                        key: const Key('result-grid'),
                        columns: [
                          for (final name in headers)
                            DataColumn(label: Text(name)),
                          if (slice.hasRowid) const DataColumn(label: Text('')),
                        ],
                        rows: [
                          for (final row in slice.rows) _row(row),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  DataRow _row(List<Object?> row) {
    final rowid =
        slice.hasRowid && row.first is BigInt ? row.first as BigInt : null;
    final values = slice.hasRowid ? row.skip(1).toList() : row;
    return DataRow(
      cells: [
        for (var i = 0; i < slice.columns.length; i++)
          DataCell(
            Text(i < values.length ? formatCell(values[i]) : ''),
            onTap: rowid == null || onEdit == null
                ? null
                : () => onEdit!(slice.columns[i], rowid, values[i]),
          ),
        if (slice.hasRowid)
          DataCell(
            IconButton(
              tooltip: 'Delete row',
              onPressed: rowid == null || onDelete == null
                  ? null
                  : () => onDelete!(rowid),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
      ],
    );
  }
}
