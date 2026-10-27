import 'dart:typed_data';

import 'tokenizer.dart';

/// One indexed term and the row positions that contain it.
final class FtsPosting {
  FtsPosting(this.term, this.rows);
  final Uint8List term;
  final List<FtsRowPosting> rows;
}

final class FtsRowPosting {
  FtsRowPosting(this.rowId, this.positions, {this.delete = false});
  final BigInt rowId;

  /// Column number to token offsets. Empty when [delete] is set.
  final Map<int, List<int>> positions;
  final bool delete;
}

final class FtsSegmentRef {
  const FtsSegmentRef(this.segid, this.firstPage, this.lastPage,
      {this.origin1 = 0,
      this.origin2 = 0,
      this.tombstonePages = 0,
      this.tombstoneEntries = 0,
      this.entries = 0});
  final int segid;
  final int firstPage;
  final int lastPage;
  final int origin1;
  final int origin2;
  final int tombstonePages;
  final int tombstoneEntries;
  final int entries;
}

const fts5LeafLimit = 4050;

int fts5LeafRowid(int segid, int page) => (segid << 37) + page;

void writeVarint(BytesBuilder out, int value) {
  if (value < 0) {
    throw const SqlException('FTS5 varint is negative');
  }
  var rest = value;
  final bytes = <int>[];
  if (rest == 0) {
    out.addByte(0);
    return;
  }
  while (rest > 0) {
    bytes.add(rest & 0x7F);
    rest >>= 7;
  }
  for (var i = bytes.length - 1; i >= 0; i--) {
    final more = i == 0 ? 0 : 0x80;
    out.addByte(bytes[i] | more);
  }
}

int readVarint(Uint8List bytes, int offset, List<int> into) {
  var value = 0;
  var index = offset;
  for (var i = 0; i < 9; i++) {
    if (index >= bytes.length) {
      throw const SqlException('Truncated FTS5 varint');
    }
    final unit = bytes[index++];
    if (i == 8) {
      value = (value << 8) | unit;
      break;
    }
    value = (value << 7) | (unit & 0x7F);
    if ((unit & 0x80) == 0) break;
  }
  into.add(value);
  return index;
}

Uint8List encodeVarints(List<int> values) {
  final out = BytesBuilder(copy: false);
  for (final value in values) {
    writeVarint(out, value);
  }
  return out.takeBytes();
}

Uint8List encodeDoclist(List<FtsRowPosting> rows) {
  if (rows.isEmpty) return Uint8List(0);
  final ordered = [...rows]..sort((a, b) => a.rowId.compareTo(b.rowId));
  final out = BytesBuilder(copy: false);
  var previous = BigInt.zero;
  for (var i = 0; i < ordered.length; i++) {
    final row = ordered[i];
    final delta = i == 0 ? row.rowId : row.rowId - previous;
    if (delta <= BigInt.zero) {
      throw const SqlException('FTS5 doclist rowids must increase');
    }
    previous = row.rowId;
    writeVarint(out, delta.toInt());
    final body = BytesBuilder(copy: false);
    if (!row.delete) {
      final columns = row.positions.keys.toList()..sort();
      for (final column in columns) {
        final positions = [...row.positions[column]!]..sort();
        if (positions.isEmpty) continue;
        if (column != 0) {
          body.addByte(1);
          writeVarint(body, column);
        }
        var last = 0;
        for (var p = 0; p < positions.length; p++) {
          final encoded = p == 0 ? positions[p] + 2 : positions[p] - last + 2;
          last = positions[p];
          writeVarint(body, encoded);
        }
      }
    }
    final payload = body.takeBytes();
    writeVarint(out, payload.length * 2 + (row.delete ? 1 : 0));
    out.add(payload);
  }
  return out.takeBytes();
}

List<FtsRowPosting> decodeDoclist(Uint8List bytes, int start, int end) {
  final rows = <FtsRowPosting>[];
  var index = start;
  var rowId = BigInt.zero;
  final holder = <int>[];
  while (index < end) {
    holder.clear();
    index = readVarint(bytes, index, holder);
    rowId = rows.isEmpty
        ? BigInt.from(holder.single)
        : rowId + BigInt.from(holder.single);
    holder.clear();
    index = readVarint(bytes, index, holder);
    final header = holder.single;
    final delete = (header & 1) != 0;
    final size = header >> 1;
    if (index + size > end) {
      throw const SqlException('Truncated FTS5 poslist');
    }
    final positions = <int, List<int>>{};
    if (!delete && size > 0) {
      final body = Uint8List.sublistView(bytes, index, index + size);
      var cursor = 0;
      var column = 0;
      if (body.isNotEmpty && body[0] == 1) {
        column = -1;
      }
      while (cursor < body.length) {
        if (body[cursor] == 1) {
          cursor++;
          holder.clear();
          cursor = readVarint(body, cursor, holder);
          column = holder.single;
        }
        final list = positions.putIfAbsent(column, () => <int>[]);
        var last = 0;
        var first = true;
        while (cursor < body.length && body[cursor] != 1) {
          holder.clear();
          cursor = readVarint(body, cursor, holder);
          final decoded = holder.single - 2;
          final position = first ? decoded : last + decoded;
          first = false;
          last = position;
          list.add(position);
        }
      }
    }
    rows.add(FtsRowPosting(rowId, positions, delete: delete));
    index += size;
  }
  return rows;
}

Uint8List encodeLeaf(List<FtsPosting> terms) {
  final ordered = [...terms]..sort((a, b) => _compareBytes(a.term, b.term));
  final body = BytesBuilder(copy: false);
  final starts = <int>[];
  Uint8List? previous;
  for (final term in ordered) {
    starts.add(4 + body.length);
    if (previous == null) {
      writeVarint(body, term.term.length);
      body.add(term.term);
    } else {
      var keep = 0;
      final limit = previous.length < term.term.length
          ? previous.length
          : term.term.length;
      while (keep < limit && previous[keep] == term.term[keep]) {
        keep++;
      }
      final suffix = term.term.sublist(keep);
      writeVarint(body, keep);
      writeVarint(body, suffix.length);
      body.add(suffix);
    }
    body.add(encodeDoclist(term.rows));
    previous = term.term;
  }
  final footer = BytesBuilder(copy: false);
  var last = 0;
  for (final start in starts) {
    writeVarint(footer, start - last);
    last = start;
  }
  final payload = body.takeBytes();
  final tail = footer.takeBytes();
  if (4 + payload.length + tail.length > fts5LeafLimit) {
    throw const SqlException(
        'FTS5 segment leaf exceeds one page; split the document');
  }
  final page = BytesBuilder(copy: false);
  final header = ByteData(4)..setUint16(2, 4 + payload.length);
  page.add(header.buffer.asUint8List());
  page.add(payload);
  page.add(tail);
  return page.takeBytes();
}

List<FtsPosting> decodeLeaf(Uint8List page) {
  if (page.length < 4) throw const SqlException('Truncated FTS5 leaf');
  final header = ByteData.sublistView(page);
  final rowidOffset = header.getUint16(0);
  final footerOffset = header.getUint16(2);
  if (rowidOffset != 0) {
    throw const SqlException('FTS5 multi-page doclist is not supported');
  }
  if (footerOffset > page.length) {
    throw const SqlException('Invalid FTS5 leaf footer');
  }
  final starts = <int>[];
  var index = footerOffset;
  var last = 0;
  final holder = <int>[];
  while (index < page.length) {
    holder.clear();
    index = readVarint(page, index, holder);
    last += holder.single;
    starts.add(last);
  }
  final terms = <FtsPosting>[];
  Uint8List? previous;
  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : footerOffset;
    holder.clear();
    var cursor = readVarint(page, start, holder);
    final Uint8List term;
    if (previous == null) {
      final size = holder.single;
      term = Uint8List.sublistView(page, cursor, cursor + size);
      cursor += size;
    } else {
      final keep = holder.single;
      holder.clear();
      cursor = readVarint(page, cursor, holder);
      final fresh = holder.single;
      term = Uint8List(keep + fresh);
      term.setRange(0, keep, previous);
      term.setRange(keep, term.length, page.sublist(cursor, cursor + fresh));
      cursor += fresh;
    }
    terms.add(FtsPosting(term, decodeDoclist(page, cursor, end)));
    previous = term;
  }
  return terms;
}

Uint8List encodeStructure(List<FtsSegmentRef> segments,
    {required bool version2}) {
  final out = BytesBuilder(copy: false);
  out.add(const [0, 0, 0, 0]);
  if (segments.isEmpty) {
    if (version2) out.add(const [0xFF, 0x00, 0x00, 0x01]);
    writeVarint(out, 0);
    writeVarint(out, 0);
    writeVarint(out, 0);
    return out.takeBytes();
  }
  if (version2) out.add(const [0xFF, 0x00, 0x00, 0x01]);
  writeVarint(out, 1);
  writeVarint(out, segments.length);
  writeVarint(out, segments.length);
  writeVarint(out, 0);
  writeVarint(out, segments.length);
  for (final segment in segments) {
    writeVarint(out, segment.segid);
    writeVarint(out, segment.firstPage);
    writeVarint(out, segment.lastPage);
    if (version2) {
      writeVarint(out, segment.origin1);
      writeVarint(out, segment.origin2);
      writeVarint(out, segment.tombstonePages);
      writeVarint(out, segment.tombstoneEntries);
      writeVarint(out, segment.entries);
    }
  }
  return out.takeBytes();
}

Uint8List encodeAverages(int rows, List<int> totals) {
  if (rows == 0) return Uint8List(0);
  return encodeVarints([rows, ...totals]);
}

Uint8List encodeDocsize(List<int> counts) => encodeVarints(counts);

/// Full terms use the leading byte `0`. Prefix index i uses `'0' + i`.
/// Token text is stored as the tokenizer's bytes, one code unit per byte.
Uint8List fts5Term(int prefixIndex, String token) =>
    Uint8List.fromList([0x30 + prefixIndex, ...token.codeUnits]);

int _compareBytes(Uint8List a, Uint8List b) {
  final limit = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < limit; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
