import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'orm_export.dart';
import 'sql_view.dart';

const _classAccents = [
  Color(0xFF0E7C66),
  Color(0xFF1C4E8A),
  Color(0xFF8A5A12),
  Color(0xFF5C4B8A),
  Color(0xFF0E6E78),
  Color(0xFF8A3D55),
];

/// The exported models, the steps that run the generator, and copy or save.
class ModelsDialog extends StatefulWidget {
  const ModelsDialog({
    super.key,
    required this.source,
    required this.onSave,
  });

  final String source;
  final Future<String?> Function(String source) onSave;

  @override
  State<ModelsDialog> createState() => _ModelsDialogState();
}

class _ModelsDialogState extends State<ModelsDialog> {
  String? _status;
  var _steps = false;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.source));
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Copy failed');
      return;
    }
    if (!mounted) return;
    setState(() => _status = 'Copied');
  }

  Future<void> _save() async {
    final stored = await widget.onSave(widget.source);
    if (!mounted || stored == null) return;
    setState(() => _status = 'Saved $stored');
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final parts = splitModelLibrary(widget.source);
    final count = parts.classes.length;
    final countLabel = count == 1 ? '1 class' : '$count classes';
    return Dialog(
      backgroundColor: const Color(0xFFF7FBF9),
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: wide ? 760 : 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Dart classes',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF14211C),
                          ),
                        ),
                        Text(
                          countLabel,
                          style: const TextStyle(
                            color: Color(0xFF5C6560),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('models-help'),
                    onPressed: () => setState(() => _steps = !_steps),
                    icon: Icon(
                      _steps ? Icons.expand_less : Icons.menu_book_outlined,
                      size: 18,
                    ),
                    label: Text(_steps ? 'Hide' : 'How to use'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF0E7C66),
                      side: const BorderSide(color: Color(0xFF0E7C66)),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ],
              ),
              if (_steps) ...[
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFD5E2DB)),
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                      children: [
                        for (var i = 0; i < ormModelSteps.length; i++)
                          _StepCard(index: i, step: ormModelSteps[i]),
                        for (final hint in ormModelHints)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              hint,
                              style: const TextStyle(
                                color: Color(0xFF5C6560),
                                height: 1.35,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: [
                    if (parts.imports.isNotEmpty) ...[
                      _Sheet(
                        child: SelectableText(
                          parts.imports.join('\n'),
                          style: sqlCodeFont.copyWith(
                            color: const Color(0xFF14211C),
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (parts.classes.isEmpty)
                      const _Sheet(
                        child: Text(
                          'This database has no table the generator can own.',
                          style: TextStyle(
                            color: Color(0xFF14211C),
                            height: 1.35,
                          ),
                        ),
                      ),
                    for (var i = 0; i < parts.classes.length; i++) ...[
                      _ClassCard(index: i, block: parts.classes[i]),
                      const SizedBox(height: 12),
                    ],
                    if (parts.notes.isNotEmpty) _NotesCard(notes: parts.notes),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_status != null)
                    Expanded(
                      child: Text(
                        _status!,
                        key: const Key('models-status'),
                        style: const TextStyle(
                          color: Color(0xFF0E7C66),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('models-save'),
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('models-copy'),
                    onPressed: _copy,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0E7C66),
                    ),
                    child: const Text('Copy'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.index, required this.step});

  final int index;
  final OrmModelStep step;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        key: Key('model-step-$index'),
        decoration: BoxDecoration(
          color: const Color(0xFFF7FBF9),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFD5E2DB)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF0E7C66),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF14211C),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      step.detail,
                      style: const TextStyle(
                        color: Color(0xFF3E524A),
                        height: 1.35,
                      ),
                    ),
                    if (step.command != null) ...[
                      const SizedBox(height: 8),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFF14211C),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: SelectableText(
                            step.command!,
                            style: sqlCodeFont.copyWith(
                              color: const Color(0xFFF4F7F5),
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClassCard extends StatelessWidget {
  const _ClassCard({required this.index, required this.block});

  final int index;
  final ModelClassBlock block;

  @override
  Widget build(BuildContext context) {
    final accent = _classAccents[index % _classAccents.length];
    final fields =
        RegExp(r'^\s*final ', multiLine: true).allMatches(block.source).length;
    final fieldLabel = fields == 1 ? '1 field' : '$fields fields';
    return DecoratedBox(
      key: Key('model-class-${block.name}'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD5E2DB)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                border: Border(left: BorderSide(color: accent, width: 6)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        block.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF14211C),
                        ),
                      ),
                    ),
                    Text(
                      fieldLabel,
                      style: const TextStyle(color: Color(0xFF5C6560)),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Text(
                            block.table,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ColoredBox(
              color: const Color(0xFF14211C),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: SelectableText.rich(
                  _codeSpan(block.source),
                  key: Key('model-code-${block.name}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.notes});

  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    return _Sheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Not generated',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF8A5A12),
            ),
          ),
          const SizedBox(height: 6),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                note,
                style: const TextStyle(
                  color: Color(0xFF3E524A),
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD5E2DB)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    );
  }
}

TextSpan _codeSpan(String source) {
  final base = sqlCodeFont.copyWith(
    color: const Color(0xFFF4F7F5),
    fontSize: 12,
    height: 1.45,
  );
  final lines = source.split('\n');
  return TextSpan(
    style: base,
    children: [
      for (var i = 0; i < lines.length; i++)
        TextSpan(
          text: i == lines.length - 1 ? lines[i] : '${lines[i]}\n',
          style: _lineStyle(base, lines[i]),
        ),
    ],
  );
}

TextStyle _lineStyle(TextStyle base, String line) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('//')) {
    return base.copyWith(color: const Color(0xFF9BB0A6));
  }
  if (trimmed.startsWith('@')) {
    return base.copyWith(color: const Color(0xFF8EE0C2));
  }
  if (trimmed.startsWith('class ') || trimmed == '}') {
    return base.copyWith(
      color: const Color(0xFFFFE3A3),
      fontWeight: FontWeight.w700,
    );
  }
  return base;
}
