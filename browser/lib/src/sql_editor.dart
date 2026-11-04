import 'package:flutter/material.dart';

import 'session.dart';
import 'sql_complete.dart';
import 'sql_view.dart';

/// The SQL editor used by the statement page and the course.
///
/// The text is colored and formatted while it is typed. The popup lists the
/// next tokens for [objects] and closes when the tap is outside the editor.
class SqlEditor extends StatefulWidget {
  const SqlEditor({
    super.key,
    required this.controller,
    required this.objects,
    this.expand = false,
    this.visibleLines = 6,
    this.hint = 'SELECT title FROM books',
    this.inputKey = const Key('sql-input'),
    this.highlightKey = const Key('sql-highlight'),
  });

  final TextEditingController controller;
  final List<SchemaObject> objects;
  final bool expand;
  final int visibleLines;
  final String hint;
  final Key inputKey;
  final Key highlightKey;

  @override
  State<SqlEditor> createState() => _SqlEditorState();
}

class _SqlEditorState extends State<SqlEditor> {
  final _portal = OverlayPortalController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _textKey = GlobalKey();
  final Object _menuGroup = Object();
  var _applying = false;
  var _menuOpen = false;
  var _textWidth = 0.0;

  static const _lineHeight = 22.0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(SqlEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
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
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _menu,
      child: TapRegion(
        groupId: _menuGroup,
        onTapOutside: (_) => _hideMenu(),
        child: _editor(),
      ),
    );
  }

  Widget _editor() {
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
                          key: widget.highlightKey,
                          TextSpan(
                            style: sqlCodeFont,
                            children: sqlHighlightSpans(text),
                          ),
                          strutStyle: sqlCodeStrut,
                        ),
                        TextField(
                          key: widget.inputKey,
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
                            hintText: text.isEmpty ? widget.hint : null,
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
        child: widget.expand
            ? scroll
            : SizedBox(
                height: 24 + widget.visibleLines * _lineHeight,
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
    const menuWidth = 300.0;
    final menuHeight = suggestions.length * 36.0 + 8;
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
                  height: 36,
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
                        _caption(item),
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

  Widget _caption(SqlCompletion item) {
    final type = item.kind == 'column' ? item.detail.trim() : '';
    final text = type.isEmpty ? item.kind : type;
    return Container(
      constraints: const BoxConstraints(maxWidth: 132),
      padding: type.isEmpty
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: type.isEmpty
          ? null
          : BoxDecoration(
              color: const Color(0xFFE7F2EC),
              borderRadius: BorderRadius.circular(8),
            ),
      child: Text(
        text,
        key: Key('suggest-type-${item.insert}'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: type.isEmpty ? null : 'JetBrainsMono',
          fontSize: type.isEmpty ? 10 : 11,
          fontWeight: type.isEmpty ? FontWeight.w500 : FontWeight.w700,
          color:
              type.isEmpty ? const Color(0xFF5E736B) : const Color(0xFF0E7C66),
        ),
      ),
    );
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
