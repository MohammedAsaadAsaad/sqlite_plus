import 'dart:io';

const maxBenchCount = 10000;

const benchCreateTable = '''
CREATE TABLE bench (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  body TEXT NOT NULL,
  n INTEGER NOT NULL
)
''';

const benchInsert = 'INSERT INTO bench(id, name, body, n) VALUES (?, ?, ?, ?)';
const benchNameIndex = 'CREATE INDEX bench_name ON bench(name)';
const benchSearch = 'SELECT id FROM bench WHERE name = ?';
const benchPoint = 'SELECT body FROM bench WHERE id = ?';
const benchUpdateOne = 'UPDATE bench SET n = n + 1 WHERE id = ?';
const benchUpdateAll = 'UPDATE bench SET n = n + 1';
const benchDeleteOne = 'DELETE FROM bench WHERE id = ?';
const benchDeleteAll = 'DELETE FROM bench';
const benchChecksum = 'SELECT COUNT(*), COALESCE(SUM(n), 0) FROM bench';
const benchVacuum = 'VACUUM';

enum BenchOp {
  separateInsert('إدراج منفصل'),
  transactionInsert('إدراج بمعاملة'),
  separateUpdate('تحديث منفصل'),
  bulkUpdate('تحديث دفعة'),
  search('بحث'),
  point('جلب بالمفتاح'),
  vacuum('VACUUM'),
  separateDelete('مسح منفصل'),
  deleteAll('مسح الكل');

  const BenchOp(this.label);
  final String label;
}

bool benchNeedsSeed(BenchOp op) => switch (op) {
  BenchOp.separateInsert || BenchOp.transactionInsert => false,
  _ => true,
};

bool benchBuildsNameIndex(BenchOp op) => op == BenchOp.search;

List<Object?> benchRow(int id) => [id, 'n$id', 'b$id', id];

int benchInsertSum(int count) => count * (count + 1) ~/ 2;

int? parseBenchCount(String text) {
  final value = int.tryParse(text.trim());
  if (value == null || value < 1 || value > maxBenchCount) return null;
  return value;
}

int benchInt(Object? value) {
  if (value is int) return value;
  if (value is BigInt) return value.toInt();
  if (value is num) return value.round();
  throw StateError('Expected an integer, got $value');
}

String formatMicros(int microseconds) {
  if (microseconds < 1000) return '$microseconds µs';
  if (microseconds < 1000000) {
    return '${(microseconds / 1000).toStringAsFixed(1)} ms';
  }
  return '${(microseconds / 1000000).toStringAsFixed(3)} s';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String formatClock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

class ProcessSample {
  const ProcessSample(this.rssBytes, this.cpuTicks);

  final int rssBytes;
  final int cpuTicks;

  static ProcessSample now() => ProcessSample(_rss(), _cpuTicks());

  int cpuMicrosSince(ProcessSample earlier) {
    final delta = cpuTicks - earlier.cpuTicks;
    if (delta <= 0) return 0;
    return (delta * 1000000) ~/ 100;
  }

  double cpuPercentSince(ProcessSample earlier, Duration elapsed) {
    final micros = elapsed.inMicroseconds;
    if (micros <= 0) return 0;
    return cpuMicrosSince(earlier) * 100 / micros;
  }
}

int _rss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return 0;
  }
}

int _cpuTicks() {
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    final end = stat.lastIndexOf(')');
    if (end < 0) return 0;
    final parts = stat.substring(end + 2).split(' ');
    if (parts.length < 13) return 0;
    return int.parse(parts[11]) + int.parse(parts[12]);
  } catch (_) {
    return 0;
  }
}

class BenchSample {
  const BenchSample({
    required this.engineId,
    required this.engineLabel,
    required this.op,
    required this.count,
    required this.elapsedMicros,
    required this.cpuMicros,
    required this.rssBefore,
    required this.rssAfter,
    required this.rows,
    required this.checksum,
    required this.hits,
    required this.prepareMicros,
    required this.exportMicros,
    required this.storedBytes,
    this.error,
  });

  final String engineId;
  final String engineLabel;
  final BenchOp op;
  final int count;
  final int elapsedMicros;
  final int cpuMicros;
  final int rssBefore;
  final int rssAfter;
  final int rows;
  final int checksum;
  final int hits;
  final int prepareMicros;
  final int exportMicros;
  final int storedBytes;
  final String? error;

  bool get failed => error != null;

  Map<String, Object?> toMessage() => {
    'kind': 'done',
    'engineId': engineId,
    'engineLabel': engineLabel,
    'op': op.index,
    'count': count,
    'elapsedMicros': elapsedMicros,
    'cpuMicros': cpuMicros,
    'rssBefore': rssBefore,
    'rssAfter': rssAfter,
    'rows': rows,
    'checksum': checksum,
    'hits': hits,
    'prepareMicros': prepareMicros,
    'exportMicros': exportMicros,
    'storedBytes': storedBytes,
    'error': error ?? '',
  };

  static BenchSample fromMessage(Map<String, Object?> message) {
    final error = message['error'] as String? ?? '';
    return BenchSample(
      engineId: message['engineId']! as String,
      engineLabel: message['engineLabel']! as String,
      op: BenchOp.values[message['op']! as int],
      count: message['count']! as int,
      elapsedMicros: message['elapsedMicros']! as int,
      cpuMicros: message['cpuMicros']! as int,
      rssBefore: message['rssBefore']! as int,
      rssAfter: message['rssAfter']! as int,
      rows: message['rows']! as int,
      checksum: message['checksum']! as int,
      hits: message['hits']! as int,
      prepareMicros: message['prepareMicros']! as int,
      exportMicros: message['exportMicros']! as int,
      storedBytes: message['storedBytes']! as int,
      error: error.isEmpty ? null : error,
    );
  }
}

class BenchLogEntry {
  const BenchLogEntry({required this.at, required this.sample});

  final DateTime at;
  final BenchSample sample;
}

abstract class BenchEngine {
  String get id;
  String get label;
  String? get location;

  Future<BenchSample> run(
    BenchOp op,
    int count,
    void Function(int done, int total) onProgress,
  );
}

void requireBenchCount(int count) {
  if (count < 1 || count > maxBenchCount) {
    throw ArgumentError.value(count, 'count', 'Use 1 through $maxBenchCount');
  }
}
