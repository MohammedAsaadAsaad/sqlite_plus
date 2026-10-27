import 'dart:convert';
import 'dart:typed_data';

import 'values.dart';

/// A geopoly polygon without the repeated closing vertex.
final class GeoPolygon {
  GeoPolygon(this.vertices);
  final List<(double, double)> vertices;
}

GeoPolygon? parseGeopoly(Object? value) {
  if (value is Uint8List) return _blob(value);
  if (value is String) {
    try {
      return _json(jsonDecode(value));
    } on FormatException {
      return null;
    }
  }
  return null;
}

Uint8List? encodeGeopoly(Object? value) {
  final polygon = parseGeopoly(value);
  if (polygon == null) return null;
  return _encode(polygon);
}

String? geopolyJson(Object? value) {
  final polygon = parseGeopoly(value);
  if (polygon == null) return null;
  final buffer = StringBuffer('[');
  for (final vertex in polygon.vertices) {
    buffer.write('[${sqlRealText(vertex.$1)},${sqlRealText(vertex.$2)}],');
  }
  final first = polygon.vertices.first;
  buffer.write('[${sqlRealText(first.$1)},${sqlRealText(first.$2)}]]');
  return buffer.toString();
}

double? geopolyArea(Object? value) {
  final polygon = parseGeopoly(value);
  if (polygon == null) return null;
  var sum = 0.0;
  for (var i = 0; i < polygon.vertices.length; i++) {
    final here = polygon.vertices[i];
    final next = polygon.vertices[(i + 1) % polygon.vertices.length];
    sum += here.$1 * next.$2 - next.$1 * here.$2;
  }
  return sum.abs() / 2;
}

/// 0 disjoint, 1 partial, 2 first inside second, 3 second inside first, 4 same.
int? geopolyOverlap(Object? left, Object? right) {
  final first = parseGeopoly(left);
  final second = parseGeopoly(right);
  if (first == null || second == null) return null;
  return _overlap(first, second);
}

/// 1 when the first polygon is inside the second, 2 when they are the same.
int? geopolyWithin(Object? left, Object? right) {
  final value = geopolyOverlap(left, right);
  if (value == null) return null;
  if (value == 2) return 1;
  if (value == 4) return 2;
  return 0;
}

GeoPolygon? _json(Object? value) {
  if (value is! List || value.length < 3) return null;
  final vertices = <(double, double)>[];
  for (final item in value) {
    if (item is! List || item.length < 2) return null;
    final x = _number(item[0]);
    final y = _number(item[1]);
    if (x == null || y == null) return null;
    vertices.add((x, y));
  }
  if (vertices.length >= 2 &&
      vertices.first.$1 == vertices.last.$1 &&
      vertices.first.$2 == vertices.last.$2) {
    vertices.removeLast();
  }
  if (vertices.length < 3) return null;
  return GeoPolygon(vertices);
}

double? _number(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

GeoPolygon? _blob(Uint8List bytes) {
  if (bytes.length < 28 || (bytes[0] != 0 && bytes[0] != 1)) return null;
  final count = (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  if (count < 3 || bytes.length != 4 + count * 8) return null;
  final data = ByteData.sublistView(bytes);
  final endian = bytes[0] == 1 ? Endian.little : Endian.big;
  final vertices = <(double, double)>[];
  for (var i = 0; i < count; i++) {
    final offset = 4 + i * 8;
    vertices.add(
        (data.getFloat32(offset, endian), data.getFloat32(offset + 4, endian)));
  }
  return GeoPolygon(vertices);
}

Uint8List _encode(GeoPolygon polygon) {
  final bytes = Uint8List(4 + polygon.vertices.length * 8);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 1;
  bytes[1] = (polygon.vertices.length >> 16) & 0xFF;
  bytes[2] = (polygon.vertices.length >> 8) & 0xFF;
  bytes[3] = polygon.vertices.length & 0xFF;
  for (var i = 0; i < polygon.vertices.length; i++) {
    data.setFloat32(4 + i * 8, polygon.vertices[i].$1, Endian.little);
    data.setFloat32(8 + i * 8, polygon.vertices[i].$2, Endian.little);
  }
  return bytes;
}

final class _Segment {
  _Segment(this.slope, this.intercept, this.y0, this.side, this.index);
  final double slope;
  final double intercept;
  final double y0;
  double y = 0;
  final int side;
  final int index;
  _Segment? next;
}

final class _Event {
  _Event(this.x, this.type, this.segment);
  final double x;
  final int type;
  final _Segment segment;
  _Event? next;
}

int _overlap(GeoPolygon left, GeoPolygon right) {
  final segments = <_Segment>[];
  final events = <_Event>[];
  void add(GeoPolygon polygon, int side) {
    for (var i = 0; i < polygon.vertices.length; i++) {
      final start = polygon.vertices[i];
      final end = polygon.vertices[(i + 1) % polygon.vertices.length];
      var x0 = start.$1, y0 = start.$2, x1 = end.$1, y1 = end.$2;
      if (x0 == x1) continue;
      if (x0 > x1) {
        final swapX = x0;
        x0 = x1;
        x1 = swapX;
        final swapY = y0;
        y0 = y1;
        y1 = swapY;
      }
      final slope = (y1 - y0) / (x1 - x0);
      final segment = _Segment(slope, y1 - x1 * slope, y0, side, i);
      segments.add(segment);
      events
        ..add(_Event(x0, 0, segment))
        ..add(_Event(x1, 1, segment));
    }
  }

  add(left, 1);
  add(right, 2);
  if (events.isEmpty) return 0;
  final first = _sortEvents(events);
  _Event? cursor = first;
  var scanX = first.x == 0 ? -1.0 : 0.0;
  _Segment? active;
  final overlap = List<int>.filled(4, 0);
  while (cursor != null) {
    if (cursor.x != scanX) {
      scanX = cursor.x;
      active = _sortSegments(active);
      var mask = 0;
      _Segment? previous;
      for (var segment = active; segment != null; segment = segment.next) {
        if (previous != null && previous.y != segment.y) overlap[mask] = 1;
        mask ^= segment.side;
        previous = segment;
      }
      previous = null;
      mask = 0;
      for (var segment = active; segment != null; segment = segment.next) {
        segment.y = segment.slope * scanX + segment.intercept;
        if (previous != null) {
          if (previous.y > segment.y && previous.side != segment.side) {
            return 1;
          }
          if (previous.y != segment.y) overlap[mask] = 1;
        }
        mask ^= segment.side;
        previous = segment;
      }
    }
    if (cursor.type == 0) {
      cursor.segment.y = cursor.segment.y0;
      cursor.segment.next = active;
      active = cursor.segment;
    } else if (identical(active, cursor.segment)) {
      active = active?.next;
    } else {
      for (var segment = active; segment != null; segment = segment.next) {
        if (identical(segment.next, cursor.segment)) {
          segment.next = segment.next?.next;
          break;
        }
      }
    }
    cursor = cursor.next;
  }
  if (overlap[3] == 0) return 0;
  if (overlap[1] != 0 && overlap[2] == 0) return 3;
  if (overlap[1] == 0 && overlap[2] != 0) return 2;
  if (overlap[1] == 0 && overlap[2] == 0) return 4;
  return 1;
}

_Event _sortEvents(List<_Event> events) {
  final pile = List<_Event?>.filled(50, null);
  var used = 0;
  for (final event in events) {
    event.next = null;
    var item = event;
    var index = 0;
    while (index < used && pile[index] != null) {
      item = _mergeEvents(pile[index]!, item);
      pile[index] = null;
      index++;
    }
    pile[index] = item;
    if (index >= used) used = index + 1;
  }
  _Event? sorted;
  for (var i = 0; i < used; i++) {
    if (pile[i] != null) sorted = _mergeEvents(pile[i]!, sorted);
  }
  return sorted!;
}

_Event _mergeEvents(_Event left, _Event? right) {
  if (right == null) return left;
  _Event? head;
  _Event? tail;
  _Event? a = left;
  _Event? b = right;
  while (a != null && b != null) {
    final take = b.x <= a.x ? b : a;
    if (identical(take, b)) {
      b = b.next;
    } else {
      a = a.next;
    }
    take.next = null;
    if (head == null) {
      head = tail = take;
    } else {
      tail!.next = take;
      tail = take;
    }
  }
  tail!.next = a ?? b;
  return head!;
}

_Segment? _sortSegments(_Segment? list) {
  final pile = List<_Segment?>.filled(50, null);
  var used = 0;
  var cursor = list;
  while (cursor != null) {
    final item = cursor;
    cursor = cursor.next;
    item.next = null;
    var merged = item;
    var index = 0;
    while (index < used && pile[index] != null) {
      merged = _mergeSegments(pile[index]!, merged);
      pile[index] = null;
      index++;
    }
    pile[index] = merged;
    if (index >= used) used = index + 1;
  }
  _Segment? sorted;
  for (var i = 0; i < used; i++) {
    if (pile[i] != null) {
      sorted = sorted == null ? pile[i] : _mergeSegments(pile[i]!, sorted);
    }
  }
  return sorted;
}

_Segment _mergeSegments(_Segment left, _Segment right) {
  _Segment? head;
  _Segment? tail;
  _Segment? a = left;
  _Segment? b = right;
  while (a != null && b != null) {
    final delta = b.y - a.y == 0 ? b.slope - a.slope : b.y - a.y;
    final take = delta < 0 ? b : a;
    if (identical(take, b)) {
      b = b.next;
    } else {
      a = a.next;
    }
    take.next = null;
    if (head == null) {
      head = tail = take;
    } else {
      tail!.next = take;
      tail = take;
    }
  }
  tail!.next = a ?? b;
  return head!;
}
