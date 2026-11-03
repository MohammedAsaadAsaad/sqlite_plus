import 'package:flutter/material.dart';

import 'format.dart';

/// A fixed-height grid. Rows are built as they scroll.
class CellGrid extends StatelessWidget {
  const CellGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.onCell,
    this.onDelete,
  });

  final List<String> columns;
  final List<List<Object?>> rows;
  final void Function(int row, int column)? onCell;
  final void Function(int row)? onDelete;

  static const width = 168.0;
  static const rowHeight = 40.0;

  @override
  Widget build(BuildContext context) {
    final delete = onDelete != null;
    final tableWidth = columns.length * width + (delete ? 52 : 0);
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: tableWidth,
          child: Column(
            children: [
              _line(
                context,
                header: true,
                children: [
                  for (final name in columns) _label(name, header: true),
                  if (delete) const SizedBox(width: 52),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemExtent: rowHeight,
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final stripe = index.isOdd;
                    return _line(
                      context,
                      stripe: stripe,
                      children: [
                        for (var column = 0; column < columns.length; column++)
                          _cell(
                            context,
                            column < row.length ? row[column] : null,
                            onTap: onCell == null
                                ? null
                                : () => onCell!(index, column),
                          ),
                        if (delete)
                          SizedBox(
                            width: 52,
                            child: IconButton(
                              tooltip: 'Delete row',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              onPressed: () => onDelete!(index),
                              icon: const Icon(Icons.delete_outline, size: 18),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(
    BuildContext context, {
    required List<Widget> children,
    bool header = false,
    bool stripe = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: header
            ? scheme.surfaceContainerHighest
            : stripe
                ? scheme.surfaceContainerLow
                : scheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: SizedBox(
        height: header ? 36 : rowHeight,
        child: Row(children: children),
      ),
    );
  }

  Widget _label(String text, {required bool header}) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: header ? 12 : 13,
            fontWeight: header ? FontWeight.w700 : FontWeight.w400,
            letterSpacing: header ? 0.2 : 0,
          ),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, Object? value, {VoidCallback? onTap}) {
    final missing = value == null;
    final child = _label(
      formatCell(value),
      header: false,
    );
    final styled = missing
        ? DefaultTextStyle.merge(
            style: TextStyle(color: Theme.of(context).hintColor),
            child: child,
          )
        : child;
    if (onTap == null) return styled;
    return InkWell(onTap: onTap, child: styled);
  }
}
