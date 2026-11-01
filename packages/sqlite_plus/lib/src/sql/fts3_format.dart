import 'dart:convert';
import 'dart:typed_data';

import 'tokenizer.dart';

/// Official content-column name: `c` + column index + the declared name.
String fts3ContentColumn(int index, String name) => 'c$index$name';

/// One term occurrence in document order.
final class Fts3Hit {
  Fts3Hit(this.docid, this.column, this.position);
  final BigInt docid;
  final int column;
  final int position;
}

/// A term and the hits that contain it, already ordered by docid.
final class Fts3Term {
  Fts3Term(this.term, this.hits);
  final Uint8List term;
  final List<Fts3Hit> hits;
}

/// Term bytes. Tokenizer output below 256 is already the on-disk byte string.
Uint8List fts3TermBytes(String text) {
  final units = text.codeUnits;
  for (final unit in units) {
    if (unit > 255) return Uint8List.fromList(utf8.encode(text));
  }
  return Uint8List.fromList(units);
}

/// FTS3 varint. Values use the unsigned 64-bit form, 7 bits at a time.
void writeFts3Varint(BytesBuilder out, BigInt value) {
  var rest = value.toUnsigned(64);
  if (rest == BigInt.zero) {
    out.addByte(0);
    return;
  }
  final bytes = <int>[];
  final mask = BigInt.from(0x7f);
  while (rest > BigInt.zero) {
    bytes.add((rest & mask).toInt());
    rest >>= 7;
  }
  for (var i = bytes.length - 1; i >= 0; i--) {
    out.addByte(bytes[i] | (i == 0 ? 0 : 0x80));
  }
}

/// Encodes [values] as a blob of FTS3 varints.
Uint8List fts3EncodeVarints(List<int> values) {
  final out = BytesBuilder(copy: false);
  for (final value in values) {
    writeFts3Varint(out, BigInt.from(value));
  }
  return out.toBytes();
}

/// Doclist: absolute first docid, then unsigned deltas, positions, and a
/// trailing 0x00 for every document.
Uint8List fts3Doclist(List<Fts3Hit> hits) {
  final out = BytesBuilder(copy: false);
  BigInt? lastDoc;
  var lastColumn = -1;
  var lastPosition = 0;
  for (final hit in hits) {
    if (lastDoc == null || hit.docid != lastDoc) {
      if (lastDoc != null) out.addByte(0);
      final delta = lastDoc == null
          ? hit.docid
          : (hit.docid.toUnsigned(64) - lastDoc.toUnsigned(64)).toUnsigned(64);
      writeFts3Varint(out, delta);
      lastColumn = -1;
      lastPosition = 0;
      lastDoc = hit.docid;
    }
    if (hit.column > 0 && lastColumn != hit.column) {
      writeFts3Varint(out, BigInt.one);
      writeFts3Varint(out, BigInt.from(hit.column));
      lastColumn = hit.column;
      lastPosition = 0;
    }
    if (hit.column >= 0) {
      writeFts3Varint(out, BigInt.from(2 + hit.position - lastPosition));
      lastPosition = hit.position;
    }
  }
  if (lastDoc != null) out.addByte(0);
  return out.toBytes();
}

/// One root leaf. The first term is prefix-compressed against an empty term,
/// which is the on-disk form stored in `segdir.root`.
Uint8List fts3RootLeaf(List<Fts3Term> terms) {
  final out = BytesBuilder(copy: false);
  Uint8List? previous;
  for (final term in terms) {
    final doclist = fts3Doclist(term.hits);
    final prefix = previous == null ? 0 : _sharedPrefix(previous, term.term);
    final suffixLength = term.term.length - prefix;
    if (suffixLength <= 0) {
      throw const SqlException('FTS3 term order is corrupt');
    }
    writeFts3Varint(out, BigInt.from(prefix));
    writeFts3Varint(out, BigInt.from(suffixLength));
    out.add(term.term.sublist(prefix));
    writeFts3Varint(out, BigInt.from(doclist.length));
    out.add(doclist);
    previous = term.term;
  }
  return out.toBytes();
}

int _sharedPrefix(Uint8List left, Uint8List right) {
  final limit = left.length < right.length ? left.length : right.length;
  var index = 0;
  while (index < limit && left[index] == right[index]) {
    index++;
  }
  return index;
}
