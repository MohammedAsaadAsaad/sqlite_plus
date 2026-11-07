import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';

/// Models loss of volatile bytes, with faults after each write/truncate/sync.
/// Immediate persistence also models storage that writes before a sync boundary.
final class PowerLoss implements Exception {}

final class Faults {
  int operations = 0;
  int? failAfter;
  bool immediatePersistence = false;
  void tick() {
    if (++operations == failAfter) throw PowerLoss();
  }
}

final class FaultStorage implements DurableStorageBackend {
  FaultStorage(Uint8List image, this.faults)
      : _volatile = Uint8List.fromList(image),
        _durable = Uint8List.fromList(image);
  final Faults faults;
  Uint8List _volatile, _durable;

  void losePower() => _volatile = Uint8List.fromList(_durable);
  void _persist() => _durable = Uint8List.fromList(_volatile);
  @override
  Future<int> length() async => _volatile.length;
  @override
  Future<int> read(int offset, Uint8List buffer) async {
    final length =
        math.max(0, math.min(buffer.length, _volatile.length - offset));
    if (length > 0) buffer.setRange(0, length, _volatile, offset);
    return length;
  }

  @override
  Future<void> write(int offset, Uint8List bytes) async {
    if (offset + bytes.length > _volatile.length) {
      _volatile = Uint8List(offset + bytes.length)
        ..setRange(0, _volatile.length, _volatile);
    }
    _volatile.setRange(offset, offset + bytes.length, bytes);
    if (faults.immediatePersistence) _persist();
    faults.tick();
  }

  @override
  Future<void> truncate(int size) async {
    _volatile = Uint8List(size)
      ..setRange(0, math.min(size, _volatile.length), _volatile);
    if (faults.immediatePersistence) _persist();
    faults.tick();
  }

  @override
  Future<void> sync() async {
    _persist();
    faults.tick();
  }

  @override
  Future<void> close() async {}
}
