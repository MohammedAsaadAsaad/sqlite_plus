import 'package:flutter/material.dart';

import 'grid.dart';
import 'session.dart';
import 'sql_complete.dart';
import 'sql_view.dart';

enum _SqlScreen { query, result }

/// One SQL statement, a caret-side popup of the next tokens, and its result.
class SqlPane extends StatefulWidget {
  const SqlPane({
    super.key,
    required this.controller,
    required this.objects,
    required this.result,
    required this.log,
    required this.busy,
    required this.onRun,
    required this.onPrevious,
    required this.onNext,
  });

  final TextEditingController controller;
  final List<SchemaObject> objects;
  final StatementResult? result;
  final List<String> log;
  final bool busy;
  final VoidCallback onRun;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<SqlPane> createState() => _SqlPaneState();
}

class _SqlPaneState extends State<SqlPane> {
  final _portal = OverlayPortalController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _textKey = GlobalKey();
  final Object _menuGroup = Object();
  var _applying = false;
  var _menuOpen = false;
  var _textWidth = 0.0;
  var _compact = false;
  var _screen = _SqlScreen.query;

  static const _lineHeight = 22.0;
  static const _visibleLines = 6;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(SqlPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (_compact &&
        !identical(widget.result, oldWidget.result) &&
        widget.result != null) {
      _screen = _SqlScreen.result;
    }
    _schedulePortal();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted || _applying) return;
    final value = widget.controller.value;
    final edited = liveSqlEdit(value.text, value.selection.baseOffset);
    final cursor = edited.cursor.clamp(0, edited.text.length);
    final textChanged = edited.text != value.text;
    final cursorChanged =
        value.selection.isCollapsed && value.selection.baseOffset != cursor;
    if (textChanged || cursorChanged) {
      _applying = true;
      widget.controller.value = TextEditingValue(
        text: edited.text,
        selection: TextSelection.collapsed(offset: cursor),
      );
      _applying = false;
    }
    setState(() => _menuOpen = true);
    _schedulePortal();
  }

  void _focusChanged() {
    if (!mounted || !_focus.hasFocus) return;
    setState(() => _menuOpen = true);
    _schedulePortal();
  }

  void _hideMenu() {
    if (!_menuOpen && !_portal.isShowing) return;
    setState(() => _menuOpen = false);
    if (_portal.isShowing) _portal.hide();
  }

  void _schedulePortal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final editorMounted = _textKey.currentContext != null;
      if (editorMounted && _menuOpen && _suggestions.isNotEmpty) {
        _portal.show();
      } else if (_portal.isShowing) {
        _portal.hide();
      }
    });
  }

  List<SqlCompletion> get _suggestions {
    final cursor = widget.controller.selection.baseOffset;
    return sqlCompletions(
      text: widget.controller.text,
      cursor: cursor,
      objects: widget.objects,
    );
  }

  void _apply(SqlCompletion completion) {
    final text = widget.controller.text;
    final cursor = widget.controller.selection.baseOffset;
    final end = cursor < 0 ? text.length : cursor.clamp(0, text.length);
    final written = '${completion.insert} ';
    final next = text.replaceRange(completion.prefixStart, end, written);
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: completion.prefixStart + written.length,
      ),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    return LayoutBuilder(
      builder: (context, constraints) {
        _compact = constraints.maxWidth < 640;
        if (_compact) return _compactPane(result);
        return _widePane(result);
      },
    );
  }

  Widget _compactPane(StatementResult? result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                  child: _screenButton(
                      'Query', _SqlScreen.query, const Key('sql-show-query'))),
              const SizedBox(width: 8),
              Expanded(
                  child: _screenButton('Result', _SqlScreen.result,
                      const Key('sql-show-result'))),
            ],
          ),
        ),
        Expanded(
          child: _screen == _SqlScreen.query
              ? _queryBody(result)
              : _resultBody(result),
        ),
      ],
    );
  }

  Widget _screenButton(String label, _SqlScreen screen, Key key) {
    final selected = _screen == screen;
    return FilledButton(
      key: key,
      style: FilledButton.styleFrom(
        backgroundColor: selected ? const Color(0xFF0E7C66) : Colors.white,
        foregroundColor: selected ? Colors.white : const Color(0xFF14211C),
        side: const BorderSide(color: Color(0xFFD5E2DB)),
        elevation: 0,
      ),
      onPressed: () => setState(() => _screen = screen),
      child: Text(label),
    );
  }

  Widget _queryBody(StatementResult? result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statementHeader(),
          const SizedBox(height: 8),
          Expanded(child: _editorPortal(expand: true)),
          if (result != null && !result.isQuery) ...[
            const SizedBox(height: 8),
            Text('${result.changes} rows changed'),
          ],
          ..._logChildren(),
        ],
      ),
    );
  }

  Widget _resultBody(StatementResult? result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Result',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          if (result == null)
            const Expanded(
              child: Center(child: Text('Run a statement to see rows here.')),
            )
          else if (!result.isQuery)
            Text('${result.changes} rows changed')
          else ...[
            Expanded(child: _gridFrame(result)),
            _pager(result),
          ],
        ],
      ),
    );
  }

  Widget _statementHeader() {
    return Row(
      children: [
        Text(
          'Statement',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const Spacer(),
        FilledButton.icon(
          key: const Key('run-sql'),
          onPressed: widget.busy ? null : widget.onRun,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Run'),
        ),
      ],
    );
  }

  Widget _editorPortal({required bool expand}) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _menu,
      child: TapRegion(
        groupId: _menuGroup,
        onTapOutside: (_) => _hideMenu(),
        child: _editor(expand: expand),
      ),
    );
  }

  List<Widget> _logChildren() {
    if (widget.log.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      const Text(
        'SQL log',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 72,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFF7FBF9),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFD5E2DB)),
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            children: [
              for (var index = 0; index < widget.log.length; index++)
                Text(
                  '${index + 1}  ${widget.log[index]}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _gridFrame(StatementResult result) {
    if (!result.isQuery || result.columns.isEmpty) {
      return const SizedBox.shrink();
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD5E2DB)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CellGrid(
          key: const Key('sql-grid'),
          columns: result.columns,
          rows: result.rows,
        ),
      ),
    );
  }

  Widget _widePane(StatementResult? result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statementHeader(),
          const SizedBox(height: 8),
          _editorPortal(expand: false),
          const SizedBox(height: 8),
          if (result != null && !result.isQuery)
            Text('${result.changes} rows changed'),
          ..._logChildren(),
          const SizedBox(height: 8),
          Expanded(
            child:
                result == null ? const SizedBox.shrink() : _gridFrame(result),
          ),
          if (result != null && result.isQuery) _pager(result),
        ],
      ),
    );
  }

  Widget _editor({bool expand = false}) {
    final text = widget.controller.text;
    final lines = text.isEmpty ? const [''] : text.split('\n');
    final scroll = LayoutBuilder(
      builder: (context, constraints) {
        final measured = _measure(text);
        final gutter = 44.0;
        final inner = constraints.maxWidth - 24;
        final textWidth = measured > inner - gutter ? measured : inner - gutter;
        _textWidth = textWidth;
        return Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _gutter(lines.length),
                  const SizedBox(width: 16),
                  SizedBox(
                    key: _textKey,
                    width: textWidth,
                    child: Stack(
                      children: [
                        Text.rich(
                          key: const Key('sql-highlight'),
                          TextSpan(
                            style: sqlCodeFont,
                            children: sqlHighlightSpans(text),
                          ),
                          strutStyle: sqlCodeStrut,
                        ),
                        TextField(
                          key: const Key('sql-input'),
                          controller: widget.controller,
                          focusNode: _focus,
                          maxLines: null,
                          autocorrect: false,
                          enableSuggestions: false,
                          smartDashesType: SmartDashesType.disabled,
                          smartQuotesType: SmartQuotesType.disabled,
                          textCapitalization: TextCapitalization.none,
                          style: sqlCodeFont.copyWith(
                            color: const Color(0x00000000),
                          ),
                          strutStyle: sqlCodeStrut,
                          cursorColor: const Color(0xFF7DDBB6),
                          cursorWidth: 1.5,
                          decoration: InputDecoration(
                            isCollapsed: true,
                            contentPadding: EdgeInsets.zero,
                            filled: false,
                            border: InputBorder.none,
                            hintText:
                                text.isEmpty ? 'SELECT title FROM books' : null,
                            hintStyle: sqlCodeFont.copyWith(
                              color: const Color(0xFF6E847C),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF17241F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2C3C36)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: expand
            ? scroll
            : SizedBox(
                height: 24 + _visibleLines * _lineHeight,
                child: scroll,
              ),
      ),
    );
  }

  Widget _gutter(int count) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < count; i++)
          SizedBox(
            height: _lineHeight,
            width: 28,
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.right,
              strutStyle: sqlCodeStrut,
              style: sqlCodeFont.copyWith(color: const Color(0xFF6E847C)),
            ),
          ),
      ],
    );
  }

  double _measure(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: sqlCodeFont),
      textDirection: TextDirection.ltr,
      strutStyle: sqlCodeStrut,
    )..layout(maxWidth: double.infinity);
    final width = painter.width + 24;
    painter.dispose();
    return width;
  }

  Widget _pager(StatementResult result) {
    return Row(
      children: [
        IconButton(
          key: const Key('sql-page-previous'),
          tooltip: 'Previous',
          onPressed: widget.busy ? null : widget.onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        Text(_range(result), key: const Key('sql-page-range')),
        IconButton(
          key: const Key('sql-page-next'),
          tooltip: 'Next',
          onPressed: widget.busy ? null : widget.onNext,
          icon: const Icon(Icons.chevron_right),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            result.columns.join(', '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _menu(BuildContext overlayContext) {
    final suggestions = _suggestions;
    final box = _textKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayObject =
        Overlay.of(overlayContext).context.findRenderObject() as RenderBox?;
    if (suggestions.isEmpty ||
        box == null ||
        !box.attached ||
        !box.hasSize ||
        overlayObject == null ||
        !overlayObject.hasSize) {
      return const SizedBox.shrink();
    }
    final width = _textWidth > 0 ? _textWidth : box.size.width;
    final painter = TextPainter(
      text: TextSpan(text: widget.controller.text, style: sqlCodeFont),
      textDirection: Directionality.of(overlayContext),
      strutStyle: sqlCodeStrut,
    )..layout(maxWidth: width);
    final rawCursor = widget.controller.selection.baseOffset;
    final cursor = rawCursor < 0
        ? widget.controller.text.length
        : rawCursor.clamp(0, widget.controller.text.length);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: cursor),
      const Rect.fromLTWH(0, 0, 1.5, _lineHeight),
    );
    painter.dispose();
    final origin = box.localToGlobal(Offset.zero, ancestor: overlayObject);
    const menuWidth = 236.0;
    final menuHeight = suggestions.length * 34.0 + 8;
    final screen = overlayObject.size;
    final keyboard = MediaQuery.viewInsetsOf(overlayContext).bottom;
    var left = origin.dx + caret.dx;
    var top = origin.dy + caret.dy + _lineHeight + 4;
    if (left + menuWidth > screen.width - 8) {
      left = screen.width - 8 - menuWidth;
    }
    if (left < 8) left = 8;
    final floor = screen.height - keyboard - 8;
    if (top + menuHeight > floor) {
      top = origin.dy + caret.dy - menuHeight - 4;
    }
    if (top < 8) top = 8;
    return Positioned(
      left: left,
      top: top,
      width: menuWidth,
      child: TapRegion(
        groupId: _menuGroup,
        child: Material(
          color: const Color(0xFFFFFDFB),
          elevation: 6,
          shadowColor: const Color(0x3314221C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFFD5E2DB)),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            itemCount: suggestions.length,
            itemBuilder: (context, index) {
              final item = suggestions[index];
              return InkWell(
                key: Key('suggest-${item.insert}'),
                onTap: () => _apply(item),
                child: SizedBox(
                  height: 34,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(
                          _icon(item.kind),
                          size: 15,
                          color: _tint(item.kind),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF14211C),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          item.kind,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF5E736B),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _range(StatementResult result) {
    if (result.rows.isEmpty) return '0 rows';
    final start = result.offset + 1;
    final end = result.offset + result.rows.length;
    return '$start–$end';
  }

  IconData _icon(String kind) {
    switch (kind) {
      case 'table':
        return Icons.table_chart_outlined;
      case 'view':
        return Icons.visibility_outlined;
      case 'column':
        return Icons.view_column_outlined;
      default:
        return Icons.data_object;
    }
  }

  Color _tint(String kind) {
    switch (kind) {
      case 'column':
        return const Color(0xFF8A6A12);
      case 'table':
      case 'view':
        return const Color(0xFF0E7C66);
      default:
        return const Color(0xFF1C4E44);
    }
  }
}
