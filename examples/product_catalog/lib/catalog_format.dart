/// User-visible timing and size text. One device sample, not a benchmark claim.
String formatElapsed(Duration elapsed) {
  final microseconds = elapsed.inMicroseconds;
  if (microseconds < 1000) return '$microseconds µs';
  if (microseconds < 1000000) {
    return '${(microseconds / 1000).toStringAsFixed(3)} ms';
  }
  return '${(microseconds / 1000000).toStringAsFixed(3)} s';
}

/// The line above a result page: the hit count and the search duration.
///
/// [listed] is how many hits this search kept. It is smaller than [total]
/// only when the result cap is reached.
String formatSearchSummary(int total, Duration elapsed, {int? listed}) {
  if (total == 0) return 'No matches · ${formatElapsed(elapsed)}';
  if (listed != null && listed < total) {
    final noun = listed == 1 ? 'match' : 'matches';
    return '${formatCount(listed)} of ${formatCount(total)} $noun · '
        '${formatElapsed(elapsed)}';
  }
  final hits = total == 1 ? '1 match' : '${formatCount(total)} matches';
  return '$hits · ${formatElapsed(elapsed)}';
}

/// Thousands separators for product counts.
String formatCount(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
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
