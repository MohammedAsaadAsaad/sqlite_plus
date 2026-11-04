import 'package:flutter/material.dart';

import 'format.dart';
import 'session.dart';

/// The value chosen in the cell editor. A null [value] is SQL NULL.
class CellEdit {
  const CellEdit(this.value);

  final Object? value;
}

/// Edits one cell with a control that matches the declared column type.
class CellDialog extends StatefulWidget {
  const CellDialog({super.key, required this.column, required this.current});

  final ColumnInfo column;
  final Object? current;

  @override
  State<CellDialog> createState() => _CellDialogState();
}

class _CellDialogState extends State<CellDialog> {
  late final TextEditingController _text = TextEditingController(
    text: editableText(widget.current),
  );
  late final CellKind _kind = cellKind(widget.column.type);
  late bool _nullValue = widget.current == null;
  late bool _on = _truthy(widget.current);

  @override
  void initState() {
    super.initState();
    _text.addListener(_refresh);
  }

  @override
  void dispose() {
    _text.removeListener(_refresh);
    _text.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  bool get _notNull => widget.column.notNull;

  String? get _error {
    if (_kind == CellKind.boolean) {
      if (_nullValue && _notNull) return 'This column cannot be NULL';
      return null;
    }
    if (_nullValue) {
      return _notNull ? 'This column cannot be NULL' : null;
    }
    final trimmed = _text.text.trim();
    if (trimmed.isEmpty) {
      return _notNull ? 'This column cannot be empty' : null;
    }
    if (!cellTextValid(_text.text, _kind)) {
      return _kind == CellKind.integer
          ? 'Enter a whole number'
          : 'Enter a decimal number';
    }
    return null;
  }

  void _save() {
    if (_error != null) return;
    final Object? value;
    if (_nullValue) {
      value = null;
    } else if (_kind == CellKind.boolean) {
      value = _on ? BigInt.one : BigInt.zero;
    } else {
      value = parseTypedCell(_text.text, _kind, nullWord: false);
    }
    Navigator.of(context).pop(CellEdit(value));
  }

  void _bump(num delta) {
    if (_kind == CellKind.integer) {
      final current = BigInt.tryParse(_text.text.trim()) ?? BigInt.zero;
      _setText((current + BigInt.from(delta)).toString());
      return;
    }
    final current = double.tryParse(_text.text.trim()) ?? 0;
    final next = current + delta;
    if (next == next.roundToDouble() && next.abs() < 1e15) {
      _setText(next.toInt().toString());
    } else {
      _setText(next.toString());
    }
  }

  void _setText(String value) {
    _text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Future<void> _pickDate() async {
    final parsed = DateTime.tryParse(_text.text.trim());
    final first = DateTime(1970);
    final last = DateTime(2100, 12, 31);
    final initial =
        parsed == null || parsed.isBefore(first) || parsed.isAfter(last)
            ? DateTime.now()
            : parsed;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked == null || !mounted) return;
    final date = _formatDate(picked);
    if (_kind == CellKind.dateTime) {
      final time = _timeSuffix(_text.text) ?? '00:00:00';
      _setText('$date $time');
    } else {
      _setText(date);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _initialTime(_text.text),
    );
    if (picked == null || !mounted) return;
    final time = _formatTime(picked);
    if (_kind == CellKind.dateTime) {
      final date = _datePrefix(_text.text) ?? _formatDate(DateTime.now());
      _setText('$date $time');
    } else {
      _setText(time);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.column.type.trim().isEmpty
        ? 'ANY'
        : widget.column.type.trim().toUpperCase();
    final marks = <String>[
      if (widget.column.primaryKey) 'PRIMARY KEY',
      if (widget.column.notNull) 'NOT NULL',
    ];
    final colors = _chipColors(_kind);
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.column.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF14211C),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    constraints: const BoxConstraints(maxWidth: 150),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.$1,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      label,
                      key: const Key('cell-kind'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: colors.$2,
                      ),
                    ),
                  ),
                ],
              ),
              if (marks.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  marks.join(' · '),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF8A6A12),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                _hint(_kind),
                style: const TextStyle(fontSize: 13, color: Color(0xFF5E736B)),
              ),
              const SizedBox(height: 14),
              Opacity(
                opacity: _nullValue ? 0.4 : 1,
                child: IgnorePointer(
                  ignoring: _nullValue,
                  child: _editor(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFF8A3A2A),
                    fontSize: 13,
                  ),
                ),
              ],
              if (!_notNull) ...[
                const SizedBox(height: 12),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F7F5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14, right: 6),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Store NULL',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF14211C),
                            ),
                          ),
                        ),
                        Switch(
                          key: const Key('cell-null'),
                          value: _nullValue,
                          onChanged: (value) =>
                              setState(() => _nullValue = value),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('cell-save'),
                    onPressed: _error == null ? _save : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editor() {
    switch (_kind) {
      case CellKind.boolean:
        return Row(
          children: [
            Expanded(child: _choice('Off', !_on)),
            const SizedBox(width: 8),
            Expanded(child: _choice('On', _on)),
          ],
        );
      case CellKind.integer:
      case CellKind.real:
        return _number();
      case CellKind.text:
        return _field(minLines: 3, maxLines: 6);
      case CellKind.date:
      case CellKind.time:
      case CellKind.dateTime:
        return _temporal();
    }
  }

  Widget _number() {
    final decimal = _kind == CellKind.real;
    final invalid = _text.text.trim().isNotEmpty && _error != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF7FBF9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: invalid ? const Color(0xFFB85C4A) : const Color(0xFFD5E2DB),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            _step(Icons.remove, -1, const Key('cell-step-down')),
            Expanded(
              child: TextField(
                key: const Key('cell-editor'),
                controller: _text,
                autofocus: true,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.numberWithOptions(
                  signed: true,
                  decimal: decimal,
                ),
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF14211C),
                ),
                decoration: const InputDecoration(
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            _step(Icons.add, 1, const Key('cell-step-up')),
          ],
        ),
      ),
    );
  }

  Widget _step(IconData icon, int delta, Key key) {
    return IconButton(
      key: key,
      onPressed: () => _bump(delta),
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: const Color(0xFFE6F0EA),
        foregroundColor: const Color(0xFF0E7C66),
        fixedSize: const Size(40, 40),
        shape: const CircleBorder(),
      ),
    );
  }

  Widget _field({int minLines = 1, int maxLines = 1, String? hint}) {
    return TextField(
      key: const Key('cell-editor'),
      controller: _text,
      autofocus: true,
      minLines: minLines,
      maxLines: maxLines,
      style: const TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 14,
        color: Color(0xFF14211C),
      ),
      decoration: InputDecoration(hintText: hint),
    );
  }

  Widget _temporal() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(hint: _hint(_kind)),
        const SizedBox(height: 8),
        Row(
          children: [
            if (_kind != CellKind.time)
              TextButton.icon(
                key: const Key('cell-pick-date'),
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: const Text('Date'),
              ),
            if (_kind != CellKind.date)
              TextButton.icon(
                key: const Key('cell-pick-time'),
                onPressed: _pickTime,
                icon: const Icon(Icons.schedule, size: 18),
                label: const Text('Time'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _choice(String label, bool selected) {
    final active = selected && !_nullValue;
    return Material(
      color: active ? const Color(0xFF0E7C66) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: active ? const Color(0xFF0E7C66) : const Color(0xFFD5E2DB),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _on = label == 'On'),
        child: SizedBox(
          height: 48,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : const Color(0xFF14211C),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _hint(CellKind kind) {
  switch (kind) {
    case CellKind.integer:
      return 'Whole number';
    case CellKind.real:
      return 'Decimal number';
    case CellKind.boolean:
      return 'On is 1, off is 0';
    case CellKind.date:
      return 'YYYY-MM-DD';
    case CellKind.time:
      return 'HH:MM:SS';
    case CellKind.dateTime:
      return 'YYYY-MM-DD HH:MM:SS';
    case CellKind.text:
      return 'Free text';
  }
}

(Color, Color) _chipColors(CellKind kind) {
  switch (kind) {
    case CellKind.integer:
      return (const Color(0xFFE4EEFF), const Color(0xFF1C4E8A));
    case CellKind.real:
      return (const Color(0xFFF8EFCF), const Color(0xFF8A6A12));
    case CellKind.boolean:
      return (const Color(0xFFEDE4F7), const Color(0xFF5B3A8C));
    case CellKind.date:
    case CellKind.time:
    case CellKind.dateTime:
      return (const Color(0xFFFDE7D8), const Color(0xFF8A4B12));
    case CellKind.text:
      return (const Color(0xFFE6F0EA), const Color(0xFF0E7C66));
  }
}

bool _truthy(Object? value) {
  if (value is bool) return value;
  if (value is BigInt) return value != BigInt.zero;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text == '1' || text == 'true' || text == 'yes' || text == 'on';
}

String _formatDate(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String _formatTime(TimeOfDay time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute:00';
}

String? _timeSuffix(String text) {
  final match = RegExp(r'(\d{2}:\d{2}(?::\d{2})?)\s*$').firstMatch(text.trim());
  if (match == null) return null;
  final found = match.group(1)!;
  return found.length == 5 ? '$found:00' : found;
}

String? _datePrefix(String text) {
  final match = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(text.trim());
  return match?.group(1);
}

TimeOfDay _initialTime(String text) {
  final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
  if (match == null) return TimeOfDay.now();
  final hour = int.tryParse(match.group(1)!);
  final minute = int.tryParse(match.group(2)!);
  if (hour == null || minute == null || hour > 23 || minute > 59) {
    return TimeOfDay.now();
  }
  return TimeOfDay(hour: hour, minute: minute);
}
