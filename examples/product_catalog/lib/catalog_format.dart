/// User-visible timing and size text. One device sample, not a benchmark claim.
String formatElapsed(Duration elapsed) {
  final microseconds = elapsed.inMicroseconds;
  if (microseconds < 1000) return '$microseconds µs';
  if (microseconds < 1000000) {
    return '${(microseconds / 1000).toStringAsFixed(3)} ms';
  }
  return '${(microseconds / 1000000).toStringAsFixed(3)} s';
}

/// Binary units, matching the database image and process RSS.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
