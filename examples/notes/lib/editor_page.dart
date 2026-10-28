import 'package:flutter/material.dart';

import 'note.dart';
import 'note_store.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.store, required this.note});

  final NoteStore store;
  final Note note;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late int _tint;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.note.title);
    _body = TextEditingController(text: widget.note.body);
    _tint = widget.note.tint;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _commit({bool pop = true}) async {
    if (_saving) return;
    setState(() => _saving = true);
    widget.note.title = _title.text;
    widget.note.body = _body.text;
    widget.note.tint = _tint;
    await widget.store.save(widget.note);
    if (!mounted) return;
    if (pop) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF1E1A16),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Delete this note?',
                style: TextStyle(
                  color: Color(0xFFF6EFE4),
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('confirm-delete'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE15A3A),
                  foregroundColor: const Color(0xFF1A120E),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    if (widget.note.id != null) await widget.store.delete(widget.note);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final paper = Color(paperForTint(_tint));
    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        backgroundColor: paper,
        foregroundColor: const Color(0xFF1C1612),
        elevation: 0,
        title: const Text(
          'Margin',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            key: const Key('editor-pin'),
            onPressed: () async {
              if (widget.note.id == null) {
                setState(() => widget.note.pinned = !widget.note.pinned);
                return;
              }
              await widget.store.togglePin(widget.note);
              if (mounted) setState(() {});
            },
            icon: Icon(
              widget.note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
            ),
          ),
          IconButton(
            key: const Key('editor-delete'),
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            key: const Key('editor-save'),
            onPressed: _commit,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('title-field'),
              controller: _title,
              maxLines: 2,
              style: const TextStyle(
                color: Color(0xFF1C1612),
                fontSize: 32,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
              cursorColor: const Color(0xFFE15A3A),
              decoration: const InputDecoration(
                hintText: 'Title',
                hintStyle: TextStyle(color: Color(0xFF8A7566)),
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final tint in notePapers.keys)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: _TintDot(
                      tint: tint,
                      selected: tint == _tint,
                      onTap: () => setState(() => _tint = tint),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                key: const Key('body-field'),
                controller: _body,
                expands: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  color: Color(0xFF2A221C),
                  fontSize: 17,
                  height: 1.55,
                ),
                cursorColor: const Color(0xFFE15A3A),
                decoration: const InputDecoration(
                  hintText: 'Write here',
                  hintStyle: TextStyle(color: Color(0xFF8A7566)),
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TintDot extends StatelessWidget {
  const _TintDot({
    required this.tint,
    required this.selected,
    required this.onTap,
  });

  final int tint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key('tint-$tint'),
      onTap: onTap,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: Color(
            paperOf(
              Note(
                title: '',
                body: '',
                updated: DateTime.utc(2020),
                tint: tint,
              ),
            ),
          ),
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF1C1612),
            width: selected ? 2 : 0.4,
          ),
        ),
      ),
    );
  }
}
