import 'package:flutter/material.dart';

/// A card shown after it has been painted and while a statement is still running.
class WorkProgress extends StatelessWidget {
  const WorkProgress({super.key, this.detail});

  /// The statement, already collapsed to one line.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final statement = detail;
    return ColoredBox(
      key: const Key('work-progress'),
      color: const Color(0x8C14221C),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Material(
              color: Colors.white,
              elevation: 10,
              shadowColor: const Color(0x3314221C),
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Color(0xFF0E7C66),
                        backgroundColor: Color(0xFFD6EBE4),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Running',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF14211C),
                          ),
                    ),
                    if (statement != null && statement.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        statement,
                        key: const Key('work-progress-detail'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12,
                          height: 1.4,
                          color: Color(0xFF5E736B),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    const ClipRRect(
                      borderRadius: BorderRadius.all(Radius.circular(99)),
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        color: Color(0xFF0E7C66),
                        backgroundColor: Color(0xFFD6EBE4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
