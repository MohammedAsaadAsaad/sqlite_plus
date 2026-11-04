import 'package:flutter/material.dart';

import 'recent_files.dart';

const _ink = Color(0xFF14211C);
const _muted = Color(0xFF5C6560);
const _line = Color(0xFFD9E2DC);

/// The screen shown when no database is open.
class HomePane extends StatelessWidget {
  const HomePane({
    super.key,
    required this.files,
    required this.onOpen,
    required this.onNew,
    required this.onRecent,
    required this.onForget,
  });

  final List<RecentFile> files;
  final VoidCallback onOpen;
  final VoidCallback onNew;
  final ValueChanged<RecentFile> onRecent;
  final ValueChanged<RecentFile> onForget;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(Radius.circular(28)),
                    border: Border.fromBorderSide(BorderSide(color: _line)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(24, 28, 24, 24),
                    child: Column(
                      children: [
                        _Mark(),
                        SizedBox(height: 16),
                        Text(
                          'SQLite Browser',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _ink,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 10),
                        SizedBox(
                          width: 48,
                          height: 3,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xFF0E7C66),
                              borderRadius:
                                  BorderRadius.all(Radius.circular(99)),
                            ),
                          ),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Open a database, or pick one you used recently.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _muted, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: Key('home-open'),
                        onPressed: onOpen,
                        icon: Icon(Icons.folder_open_outlined),
                        label: Text('Open'),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: Key('home-new'),
                        onPressed: onNew,
                        icon: Icon(Icons.note_add_outlined),
                        label: Text('New'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                const Text(
                  'Recent',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (files.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Recent files will appear here.',
                      style: TextStyle(color: _muted),
                    ),
                  )
                else
                  for (var index = 0; index < files.length; index++)
                    _tile(files[index], index),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(RecentFile file, int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _line),
        ),
        child: ListTile(
          key: Key('recent-$index'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          contentPadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          title: Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, color: _ink),
          ),
          subtitle: Text(
            recentPlace(file),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          trailing: IconButton(
            key: Key('recent-forget-$index'),
            tooltip: 'Remove',
            onPressed: () => onForget(file),
            icon: const Icon(Icons.close, size: 18),
          ),
          onTap: () => onRecent(file),
        ),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Image.asset(
        'assets/app_icon.png',
        width: 88,
        height: 88,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
