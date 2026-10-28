import 'package:flutter/material.dart';

import 'editor_page.dart';
import 'note.dart';
import 'note_store.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.store});

  final NoteStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final notes = store.visible;
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Masthead(),
                  const SizedBox(height: 18),
                  _SearchField(onChanged: store.setSearch),
                  const SizedBox(height: 18),
                  Expanded(
                    child: notes.isEmpty
                        ? const _EmptyDesk()
                        : GridView.builder(
                            key: const Key('note-grid'),
                            padding: const EdgeInsets.only(bottom: 108),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 0.78,
                                ),
                            itemCount: notes.length,
                            itemBuilder: (context, index) {
                              final note = notes[index];
                              return _NoteCard(
                                note: note,
                                onOpen: () => _open(context, note),
                                onPin: () => store.togglePin(note),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
          floatingActionButton: _ComposeButton(
            onPressed: () async {
              final note = store.draft();
              if (!context.mounted) return;
              await _open(context, note);
            },
          ),
        );
      },
    );
  }

  Future<void> _open(BuildContext context, Note note) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (context, animation, _) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, 0.06),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: EditorPage(store: store, note: note),
            ),
          );
        },
      ),
    );
  }
}

class _Masthead extends StatelessWidget {
  const _Masthead();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MARGIN',
          style: TextStyle(
            color: Color(0xFFE15A3A),
            fontSize: 12,
            letterSpacing: 3.2,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'هامش',
          style: TextStyle(
            color: Color(0xFFF6EFE4),
            fontSize: 40,
            height: 1.1,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          'ملاحظات على المكتب',
          style: TextStyle(color: Color(0xFFB7A89A), fontSize: 13),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('search'),
      onChanged: onChanged,
      style: const TextStyle(color: Color(0xFFF6EFE4)),
      cursorColor: const Color(0xFFE15A3A),
      decoration: InputDecoration(
        hintText: 'ابحث في الهامش',
        hintStyle: const TextStyle(color: Color(0xFF8C7D70)),
        prefixIcon: const Icon(Icons.search, color: Color(0xFFE15A3A)),
        filled: true,
        fillColor: const Color(0xFF1E1A16),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.onOpen,
    required this.onPin,
  });

  final Note note;
  final VoidCallback onOpen;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final paper = Color(paperOf(note));
    final title = note.title.trim().isEmpty ? 'بدون عنوان' : note.title.trim();
    return Material(
      color: paper,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF1C1612),
                        fontSize: 18,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('pin-${note.id}'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onPin,
                    icon: Icon(
                      note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      color: note.pinned
                          ? const Color(0xFFE15A3A)
                          : const Color(0xFF6E5E52),
                      size: 18,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  note.body.trim().isEmpty ? '...' : note.body.trim(),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF3C312A),
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
              Text(
                _when(note.updated),
                style: const TextStyle(color: Color(0xFF6E5E52), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDesk extends StatelessWidget {
  const _EmptyDesk();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _DeskMark(),
        SizedBox(height: 18),
        Text(
          'المكتب فارغ',
          style: TextStyle(
            color: Color(0xFFF6EFE4),
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'أول ملاحظة تبدأ من الزر المرجاني',
          style: TextStyle(color: Color(0xFFB7A89A)),
        ),
      ],
    );
  }
}

class _DeskMark extends StatelessWidget {
  const _DeskMark();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(92, 72), painter: _DeskPainter());
  }
}

class _DeskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paper = Paint()..color = const Color(0xFFF4E7D4);
    final ink = Paint()
      ..color = const Color(0xFFE15A3A)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final card = RRect.fromRectAndRadius(
      Rect.fromLTWH(8, 10, size.width - 16, size.height - 14),
      const Radius.circular(12),
    );
    canvas.drawRRect(card, paper);
    canvas.drawLine(const Offset(22, 28), Offset(size.width - 22, 28), ink);
    final rule = Paint()
      ..color = const Color(0xFFCDB8A2)
      ..strokeWidth = 2;
    for (var y = 40.0; y < size.height - 12; y += 10) {
      canvas.drawLine(Offset(22, y), Offset(size.width - 22, y), rule);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ComposeButton extends StatelessWidget {
  const _ComposeButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      key: const Key('compose'),
      backgroundColor: const Color(0xFFE15A3A),
      foregroundColor: const Color(0xFF1A120E),
      elevation: 0,
      onPressed: onPressed,
      icon: const Icon(Icons.edit_outlined),
      label: const Text(
        'ملاحظة',
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    );
  }
}

String _when(DateTime utc) {
  final local = utc.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final gap = today.difference(day).inDays;
  if (gap == 0) return 'اليوم $clock';
  if (gap == 1) return 'أمس $clock';
  return '${local.day}/${local.month} $clock';
}
