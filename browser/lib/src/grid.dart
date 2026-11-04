import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'format.dart';

/// A fixed-height grid. Rows are built as they scroll.
class CellGrid extends StatelessWidget {
  const CellGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.sortColumn,
    this.sortAscending = true,
    this.searched = const {},
    this.onColumn,
    this.onCell,
    this.onDelete,
    this.linkedColumns = const {},
    this.onLink,
    this.openLink,
    this.relatedIndent = 0,
    this.relatedWidth = 0,
    this.relatedPanel,
  });

  final List<String> columns;
  final List<List<Object?>> rows;

  /// The column currently ordered, when the header menu is in use.
  final String? sortColumn;

  final bool sortAscending;

  /// Columns that have a search.
  final Set<String> searched;

  /// Opens the sort and search menu for one column.
  final ValueChanged<String>? onColumn;
  final void Function(int row, int column)? onCell;
  final void Function(int row)? onDelete;

  /// Columns that reference another table.
  final Set<String> linkedColumns;

  /// Opens or closes the related rows for one column.
  final ValueChanged<String>? onLink;

  /// The column whose related table is open.
  final String? openLink;

  /// How far the related table sits from the left, under its column.
  final double relatedIndent;

  /// Width of [relatedPanel], used so the horizontal scroll can reach it.
  final double relatedWidth;

  /// The one related table, shown directly under the header.
  final Widget? relatedPanel;

  static const width = 168.0;
  static const rowHeight = 40.0;

  @override
  Widget build(BuildContext context) {
    final delete = onDelete != null;
    final tableWidth = columns.length * width + (delete ? 52 : 0);
    final related = relatedPanel;
    final boardWidth = related == null
        ? tableWidth
        : math.max(tableWidth, relatedIndent + relatedWidth);
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: boardWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: tableWidth,
                child: _line(
                  context,
                  header: true,
                  children: [
                    for (final name in columns) _header(name),
                    if (delete) const SizedBox(width: 52),
                  ],
                ),
              ),
              if (related != null)
                Padding(
                  padding: EdgeInsets.only(left: relatedIndent),
                  child: related,
                ),
              Expanded(
                child: SizedBox(
                  width: tableWidth,
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
                          for (var column = 0;
                              column < columns.length;
                              column++)
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
                                key: Key('delete-row-$index'),
                                tooltip: 'Delete row',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 40,
                                  minHeight: 40,
                                ),
                                onPressed: () => onDelete!(index),
                                icon:
                                    const Icon(Icons.delete_outline, size: 18),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(String name) {
    final open = onColumn;
    final linked = onLink != null && linkedColumns.contains(name);
    if (open == null && !linked) return _label(name, header: true);
    final sorted = sortColumn == name;
    final active = sorted || searched.contains(name);
    final icon = sorted
        ? (sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
        : searched.contains(name)
            ? Icons.filter_alt
            : Icons.arrow_drop_down;
    final title = Expanded(
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            color: Color(0xFF1A3C32),
          ),
        ),
      ),
    );
    final menu = open == null
        ? title
        : Expanded(
            child: InkWell(
              key: Key('column-menu-$name'),
              onTap: () => open(name),
              child: Row(
                children: [
                  title,
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      icon,
                      size: active ? 14 : 18,
                      color: active
                          ? const Color(0xFF0E7C66)
                          : const Color(0xFF5C6560),
                    ),
                  ),
                ],
              ),
            ),
          );
    return SizedBox(
      width: width,
      child: Row(
        children: [
          menu,
          if (linked)
            IconButton(
              key: Key('related-rows-$name'),
              tooltip: openLink == name ? 'Hide related rows' : 'Related rows',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: () => onLink!(name),
              icon: Icon(
                openLink == name ? Icons.table_rows : Icons.table_rows_outlined,
                size: 16,
                color: const Color(0xFF0E7C66),
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context, {
    required List<Widget> children,
    bool header = false,
    bool stripe = false,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: header
            ? const Color(0xFFE6F0EA)
            : stripe
                ? const Color(0xFFF7FBF9)
                : Colors.white,
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

  Widget _label(String text, {required bool header, Color? color}) {
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
            fontWeight: header ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: header ? 0.3 : 0,
            color: color ??
                (header ? const Color(0xFF1A3C32) : const Color(0xFF14211C)),
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
      color: missing ? const Color(0xFF8AA097) : null,
    );
    if (onTap == null) return child;
    return InkWell(onTap: onTap, child: child);
  }
}
