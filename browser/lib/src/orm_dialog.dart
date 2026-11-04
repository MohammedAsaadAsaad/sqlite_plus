import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'orm_export.dart';
import 'sql_view.dart';

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
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: wide ? 760 : 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Dart classes',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < ormModelSteps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${i + 1}. ${ormModelSteps[i]}',
                    key: Key('model-step-$i'),
                    style: const TextStyle(color: Color(0xFF14211C)),
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF14211C),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: SelectableText(
                        widget.source,
                        key: const Key('models-source'),
                        style: sqlCodeFont.copyWith(
                          color: const Color(0xFFF4F7F5),
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
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
