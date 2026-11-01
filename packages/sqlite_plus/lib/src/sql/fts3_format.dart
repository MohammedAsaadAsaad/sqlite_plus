import 'dart:convert';
import 'dart:typed_data';

import 'fts_text.dart';
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

/// Terms stored in one `segdir.root` leaf.
List<Fts3Term> fts3DecodeRoot(Uint8List root) {
  final terms = <Fts3Term>[];
  var offset = 0;
  Uint8List? previous;
  while (offset < root.length) {
    final prefix = _fts3Varint(root, offset);
    offset = prefix.$2;
    final suffix = _fts3Varint(root, offset);
    offset = suffix.$2;
    final suffixLength = suffix.$1.toInt();
    if (suffixLength < 0 || offset + suffixLength > root.length) {
      throw const FormatException('Truncated FTS3 term');
    }
    final prefixLength = prefix.$1.toInt();
    if (previous == null && prefixLength != 0 ||
        previous != null && prefixLength > previous.length) {
      throw const FormatException('Invalid FTS3 term prefix');
    }
    final term = Uint8List(prefixLength + suffixLength);
    if (prefixLength > 0) {
      term.setRange(0, prefixLength, previous!);
    }
    term.setRange(prefixLength, term.length, root, offset);
    offset += suffixLength;
    final length = _fts3Varint(root, offset);
    offset = length.$2;
    final doclistLength = length.$1.toInt();
    if (doclistLength < 0 || offset + doclistLength > root.length) {
      throw const FormatException('Truncated FTS3 doclist');
    }
    final doclist = Uint8List.sublistView(root, offset, offset + doclistLength);
    offset += doclistLength;
    terms.add(Fts3Term(term, _fts3Doclist(doclist)));
    previous = term;
  }
  return terms;
}

/// Token lists keyed by docid. Column lists are position-aligned.
Map<BigInt, List<List<FtsToken>>> fts3IndexDocuments(
    Iterable<Uint8List> roots, int columns) {
  final documents = <BigInt, List<List<FtsToken>>>{};
  for (final root in roots) {
    for (final term in fts3DecodeRoot(root)) {
      final text = String.fromCharCodes(term.term);
      for (final hit in term.hits) {
        if (hit.column < 0 || hit.column >= columns) continue;
        final lists = documents.putIfAbsent(
            hit.docid, () => List.generate(columns, (_) => <FtsToken>[]));
        final tokens = lists[hit.column];
        while (tokens.length <= hit.position) {
          tokens.add(const FtsToken('', 0, 0));
        }
        tokens[hit.position] = FtsToken(text, 0, text.length);
      }
    }
  }
  return documents;
}

(BigInt, int) _fts3Varint(Uint8List bytes, int offset) {
  var result = BigInt.zero;
  var cursor = offset;
  for (var i = 0; i < 8; i++) {
    if (cursor >= bytes.length) {
      throw const FormatException('Truncated FTS3 varint');
    }
    final value = bytes[cursor++];
    result = (result << 7) | BigInt.from(value & 0x7f);
    if (value < 0x80) return (result, cursor);
  }
  if (cursor >= bytes.length) {
    throw const FormatException('Truncated FTS3 varint');
  }
  return ((result << 8) | BigInt.from(bytes[cursor]), cursor + 1);
}

List<Fts3Hit> _fts3Doclist(Uint8List bytes) {
  final hits = <Fts3Hit>[];
  var offset = 0;
  BigInt? docid;
  while (offset < bytes.length) {
    if (docid != null) {
      if (bytes[offset] != 0) {
        throw const FormatException('Invalid FTS3 doclist');
      }
      offset++;
      if (offset >= bytes.length) break;
    }
    final delta = _fts3Varint(bytes, offset);
    offset = delta.$2;
    docid = docid == null
        ? delta.$1
        : (docid.toUnsigned(64) + delta.$1.toUnsigned(64)).toUnsigned(64);
    var column = 0;
    var position = 0;
    while (offset < bytes.length && bytes[offset] != 0) {
      final value = _fts3Varint(bytes, offset);
      offset = value.$2;
      if (value.$1 == BigInt.one) {
        final next = _fts3Varint(bytes, offset);
        offset = next.$2;
        column = next.$1.toInt();
        position = 0;
        continue;
      }
      final code = value.$1.toInt();
      if (code < 2) throw const FormatException('Invalid FTS3 position');
      position += code - 2;
      hits.add(Fts3Hit(docid, column, position));
    }
  }
  return hits;
}

int _sharedPrefix(Uint8List left, Uint8List right) {
  final limit = left.length < right.length ? left.length : right.length;
  var index = 0;
  while (index < limit && left[index] == right[index]) {
    index++;
  }
  return index;
}
