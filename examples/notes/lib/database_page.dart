import 'package:flutter/material.dart';

import 'note.dart';
import 'note_store.dart';

class DatabasePage extends StatelessWidget {
  const DatabasePage({super.key, required this.snapshot});

  final DatabaseSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12100E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12100E),
        foregroundColor: const Color(0xFFF6EFE4),
        elevation: 0,
        title: const Text(
          'Database',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _Fact(label: 'Path', value: snapshot.path),
          _Fact(label: 'File size', value: formatBytes(snapshot.fileBytes)),
          _Fact(label: 'Image size', value: formatBytes(snapshot.imageBytes)),
          _Fact(label: 'Pages', value: '${snapshot.pageCount}'),
          _Fact(label: 'Page size', value: formatBytes(snapshot.pageSize)),
          _Fact(
            label: 'Free pages',
            value:
                '${snapshot.freelistCount} · ${formatBytes(snapshot.freelistBytes)}',
          ),
          _Fact(label: 'Notes', value: '${snapshot.noteCount}'),
          const SizedBox(height: 18),
          const Text(
            'Objects',
            style: TextStyle(
              color: Color(0xFFE15A3A),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final object in snapshot.objects)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${object.type}  ${object.name}',
                style: const TextStyle(color: Color(0xFFF6EFE4)),
              ),
            ),
          const SizedBox(height: 18),
          const Text(
            'Rows',
            style: TextStyle(
              color: Color(0xFFE15A3A),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final note in snapshot.notes) _NoteRow(note: note),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFFB7A89A), fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            key: Key('fact-$label'),
            style: const TextStyle(color: Color(0xFFF6EFE4), fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final title = note.title.trim().isEmpty ? 'Untitled' : note.title.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color(paperOf(note)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF1C1612),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            note.body,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF3C312A), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            'id ${note.id ?? '-'} · tint ${note.tint} · ${note.pinned ? 'pinned' : 'free'}',
            style: const TextStyle(color: Color(0xFF6E5E52), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String formatDuration(int microseconds) {
  if (microseconds < 1000) return '$microseconds µs';
  if (microseconds < 1000000) {
    return '${(microseconds / 1000).toStringAsFixed(1)} ms';
  }
  return '${(microseconds / 1000000).toStringAsFixed(3)} s';
}
