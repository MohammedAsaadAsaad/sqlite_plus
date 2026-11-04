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
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Image.asset(
              'assets/app_icon.png',
              width: 96,
              height: 96,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Sqlite Browser',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _ink,
            fontSize: 28,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Open a database, or pick one you used recently.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 14),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('home-open'),
                onPressed: onOpen,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('home-new'),
                onPressed: onNew,
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('New'),
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
