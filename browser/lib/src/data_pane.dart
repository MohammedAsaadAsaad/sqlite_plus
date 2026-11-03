import 'package:flutter/material.dart';

import 'grid.dart';
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
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            object.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          SelectableText(
            object.sql ?? object.name,
            style: const TextStyle(fontFamily: 'monospace', height: 1.4),
          ),
        ],
      );
    }
    final start = slice.rows.isEmpty ? slice.offset : slice.offset + 1;
    final end = slice.offset + slice.rows.length;
    final range =
        slice.totalKnown ? '$start–$end of ${slice.total}' : '$start–$end';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                object.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(range, key: const Key('page-range')),
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
              OutlinedButton.icon(
                key: const Key('page-previous'),
                onPressed: busy ? null : onPrevious,
                icon: const Icon(Icons.chevron_left),
                label: const Text('Previous'),
              ),
              OutlinedButton.icon(
                key: const Key('page-next'),
                onPressed: busy ? null : onNext,
                icon: const Icon(Icons.chevron_right),
                label: const Text('Next'),
              ),
            ],
          ),
        ),
        if (!slice.hasRowid && object.type == 'table')
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('This table has no rowid. Change it with SQL.'),
          ),
        Expanded(
          child: slice.rows.isEmpty
              ? const Center(child: Text('This table has no rows.'))
              : CellGrid(
                  key: const Key('result-grid'),
                  columns: [
                    for (final column in slice.columns) column.name,
                  ],
                  rows: [
                    for (final row in slice.rows)
                      slice.hasRowid ? row.skip(1).toList() : row,
                  ],
                  onCell: (index, column) {
                    final source = slice.rows[index];
                    final rowid = slice.hasRowid && source.first is BigInt
                        ? source.first as BigInt
                        : null;
                    if (rowid == null || onEdit == null) return;
                    final values =
                        slice.hasRowid ? source.skip(1).toList() : source;
                    onEdit!(
                      slice.columns[column],
                      rowid,
                      column < values.length ? values[column] : null,
                    );
                  },
                  onDelete: slice.hasRowid
                      ? (index) {
                          final source = slice.rows[index];
                          if (source.first is! BigInt || onDelete == null) {
                            return;
                          }
                          onDelete!(source.first as BigInt);
                        }
                      : null,
                ),
        ),
      ],
    );
  }
}
