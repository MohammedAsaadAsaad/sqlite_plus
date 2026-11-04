import 'package:flutter/material.dart';

/// How a page notice should be read.
enum NoticeKind { error, ok, note }

/// One short notice under the app bar.
class PageNotice {
  const PageNotice(this.text, this.kind);

  final String text;
  final NoticeKind kind;
}

/// A rounded notice with a color that matches [PageNotice.kind].
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.notice,
    required this.onClose,
  });

  final PageNotice notice;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tone = _tone(notice.kind);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Material(
        color: tone.background,
        elevation: 2,
        shadowColor: const Color(0x3314221C),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(tone.icon, color: tone.foreground, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  notice.text,
                  style: TextStyle(
                    color: tone.foreground,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: onClose,
                icon: Icon(Icons.close, color: tone.foreground, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tone {
  const _Tone(this.background, this.foreground, this.icon);

  final Color background;
  final Color foreground;
  final IconData icon;
}

_Tone _tone(NoticeKind kind) {
  return switch (kind) {
    NoticeKind.error => const _Tone(
        Color(0xFFC4473A),
        Colors.white,
        Icons.error_outline,
      ),
    NoticeKind.ok => const _Tone(
        Color(0xFF0E7C66),
        Colors.white,
        Icons.check_circle_outline,
      ),
    NoticeKind.note => const _Tone(
        Color(0xFF1C4E8A),
        Colors.white,
        Icons.info_outline,
      ),
  };
}
