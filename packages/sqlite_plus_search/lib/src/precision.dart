part of 'search.dart';

final class _Precision {
  const _Precision(this.quality, this.fieldScore);
  final MatchQuality quality;
  final double fieldScore;
}

_Precision _precision(List<String> query, Map<String, List<String>> fields,
    SearchRankingPolicy policy, Map<String, List<String>>? alternatives) {
  if (query.isEmpty) return const _Precision(MatchQuality.partial, 0);
  final required = query.toSet();
  final all = <String>{};
  var quality = MatchQuality.partial;
  var fieldScore = 0.0;
  for (final entry in fields.entries) {
    final words = entry.value;
    final unique = words.toSet();
    all.addAll(unique);
    var coverage = 0;
    for (final term in required) {
      if ((alternatives?[term] ?? [term]).any(unique.contains)) coverage++;
    }
    fieldScore +=
        coverage / required.length * (policy.fieldWeights[entry.key] ?? 1);
    if (!required.every(unique.contains)) continue;
    if (words.length == query.length && _sameWords(words, query, 0)) {
      quality = MatchQuality.exact;
      continue;
    }
    if (quality == MatchQuality.exact) continue;
    for (var start = 0; start + query.length <= words.length; start++) {
      if (_sameWords(words, query, start)) {
        quality = MatchQuality.phrase;
        break;
      }
    }
    if (quality == MatchQuality.phrase) continue;
    if (_adjacentWords(words, query)) quality = MatchQuality.adjacent;
  }
  if (quality == MatchQuality.partial) {
    if (required.every(all.contains)) {
      quality = MatchQuality.allWords;
    } else if (alternatives != null &&
        required.every(
            (term) => (alternatives[term] ?? [term]).any(all.contains))) {
      quality = MatchQuality.corrected;
    }
  }
  return _Precision(quality, fieldScore);
}

bool _sameWords(List<String> words, List<String> query, int start) {
  for (var i = 0; i < query.length; i++) {
    if (words[start + i] != query[i]) return false;
  }
  return true;
}

bool _adjacentWords(List<String> words, List<String> query) {
  if (words.length < query.length) return false;
  final needed = <String, int>{};
  for (final term in query) {
    needed[term] = (needed[term] ?? 0) + 1;
  }
  final window = <String, int>{};
  for (var i = 0; i < words.length; i++) {
    window[words[i]] = (window[words[i]] ?? 0) + 1;
    if (i >= query.length) {
      final old = words[i - query.length];
      window[old] = window[old]! - 1;
      if (window[old] == 0) window.remove(old);
    }
    if (i >= query.length - 1 &&
        window.length == needed.length &&
        needed.entries.every((e) => window[e.key] == e.value)) {
      return true;
    }
  }
  return false;
}
