import 'dart:math';

/// One searchable thing: its fields (title first, then artist, album…) with how much a match
/// in each counts, how popular it is and how much it's trending (both 0..1).
class SearchDoc<T> {
  SearchDoc({
    required this.key,
    required this.value,
    required List<(String, double)> fields,
    this.popularity = 0,
    this.trending = 0,
  }) : fields = [for (final (text, weight) in fields) SearchField(text, weight)];

  final String key;
  T value;
  final List<SearchField> fields;
  double popularity;
  double trending;
}

/// A match: how well the text fits (0..1) and the final score with popularity mixed in.
class SearchHit<T> {
  const SearchHit(this.value, this.relevance, this.score, this.popularity);

  final T value;
  final double relevance;
  final double score;
  final double popularity;
}

/// One field of a [SearchDoc], broken into words once.
class SearchField {
  SearchField(String text, this.weight) : words = SearchText.words(text), squashed = SearchText.squash(text);

  final List<String> words;
  final String squashed;
  final double weight;
}

/// Atlas: a small on-device fuzzy index, ranked the way Meilisearch ranks (every word found,
/// fewest typos, best field, exact matches first), except popularity and trending get a real
/// say: a name one letter off that millions play beats an exact name nobody does. That's how
/// "siza" means SZA and "ajr" means the band.
///
/// It keeps everything it's been shown this session (up to [capacity]), so later searches get
/// instant results from earlier ones while the network catches up.
class MusicSearchIndex<T> {
  MusicSearchIndex({this.capacity = 4000});

  final int capacity;
  final Map<String, SearchDoc<T>> _docs = {};

  int get length => _docs.length;

  /// Add [doc], or update the one with its key (keeping the higher popularity).
  void put(SearchDoc<T> doc) {
    final existing = _docs.remove(doc.key);
    if (existing != null) {
      doc
        ..popularity = max(doc.popularity, existing.popularity)
        ..trending = max(doc.trending, existing.trending);
    }
    _docs[doc.key] = doc;
    while (_docs.length > capacity) {
      _docs.remove(_docs.keys.first);
    }
  }

  SearchDoc<T>? operator [](String key) => _docs[key];

  /// Everything matching [query] at least [minRelevance], best first.
  List<SearchHit<T>> search(String query, {double minRelevance = 0.5, int limit = 50}) {
    final words = SearchText.words(query);
    final squashed = SearchText.squash(query);
    if (words.isEmpty || squashed.isEmpty) return const [];
    final hits = <SearchHit<T>>[];
    for (final doc in _docs.values) {
      final relevance = relevanceOf(words, squashed, doc.fields);
      if (relevance < minRelevance) continue;
      hits.add(SearchHit(doc.value, relevance, combine(relevance, doc.popularity, doc.trending), doc.popularity));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  /// The final order: text first, then how many people play it, then what's hot right now.
  static double combine(double relevance, double popularity, double trending) =>
      relevance * 0.55 + popularity * 0.3 + trending * 0.15;

  /// How well [query] fits [fields], 0..1.
  static double relevance(String query, List<(String, double)> fields) => relevanceOf(
    SearchText.words(query),
    SearchText.squash(query),
    [for (final (text, weight) in fields) SearchField(text, weight)],
  );

  static double relevanceOf(List<String> query, String squashed, List<SearchField> fields) {
    var best = 0.0;
    // The whole query against one field ("ajr", "a.j.r.", "siza" against "sza").
    for (final field in fields) {
      final words = _words(query, field.words);
      final whole = _word(squashed, field.squashed, last: true);
      var score = max(words, whole * 0.97);
      // Exactness: every word, nothing left over.
      if (words >= 0.999 && field.words.length == query.length) score = min(1.0, score + 0.06);
      best = max(best, score * field.weight);
    }
    // Words spread over fields ("bang ajr": the title and the artist).
    if (query.length > 1 && fields.length > 1) {
      var total = 0.0;
      for (final (index, word) in query.indexed) {
        var wordBest = 0.0;
        for (final field in fields) {
          for (final candidate in field.words) {
            wordBest = max(wordBest, _word(word, candidate, last: index == query.length - 1) * field.weight);
          }
        }
        total += wordBest;
      }
      best = max(best, total / query.length * 0.97);
    }
    return best.clamp(0.0, 1.0);
  }

  /// Each query word against its best word in [field], averaged (a missing word counts zero).
  static double _words(List<String> query, List<String> field) {
    if (field.isEmpty) return 0;
    var total = 0.0;
    for (final (index, word) in query.indexed) {
      var wordBest = 0.0;
      for (final candidate in field) {
        wordBest = max(wordBest, _word(word, candidate, last: index == query.length - 1));
        if (wordBest >= 1) break;
      }
      total += wordBest;
    }
    return total / query.length;
  }

  /// One query word against one word: exact, a prefix (the word still being typed), or a
  /// typo or two away (none for very short words, like Meilisearch).
  static double _word(String query, String word, {required bool last}) {
    if (query.isEmpty || word.isEmpty) return 0;
    if (query == word) return 1;
    if (word.startsWith(query)) {
      if (last) return 0.92 - min(0.12, (word.length - query.length) * 0.01);
      if (query.length >= 3) return 0.8;
    }
    final allowed = query.length < 3 ? 0 : (query.length < 6 ? 1 : 2);
    if (allowed == 0) return 0;
    var typos = SearchText.distance(query, word);
    // The last word may be half typed: compare against the start of the candidate too.
    if (last && word.length > query.length) {
      typos = min(typos, SearchText.distance(query, word.substring(0, query.length)));
    }
    if (typos > allowed) return 0;
    return typos == 1 ? 0.8 : 0.65;
  }
}

/// Text helpers shared by search and linking.
abstract final class SearchText {
  static const _accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae', 'ç': 'c', 'è': 'e',
    'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o',
    'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y', 'ß': 'ss', 'œ': 'oe', '\$': 's',
  };

  static String _fold(String value) {
    final lower = value.toLowerCase();
    final buffer = StringBuffer();
    for (final char in lower.split('')) {
      buffer.write(_accents[char] ?? char);
    }
    return buffer.toString().replaceAll('&', ' and ');
  }

  /// Lowercase words without accents or punctuation ("Beyoncé & JAY-Z" → beyonce, and, jay, z).
  static List<String> words(String value) =>
      _fold(value).split(RegExp(r'[^a-z0-9]+')).where((word) => word.isNotEmpty).toList();

  /// Everything run together ("A.J.R." → "ajr", "Ke$ha" → "kesha").
  static String squash(String value) => _fold(value).replaceAll(RegExp(r'[^a-z0-9]+'), '');

  /// "Bang! - Single", "Good News (feat. Mac Miller) [Deluxe]" → "Bang!", "Good News".
  static String cleanTitle(String value) => value
      .replaceAll(RegExp(r'\s+-\s+(Single|EP)$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*[(\[](feat\.?|ft\.?|featuring|with)\s[^)\]]*[)\]]', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*[(\[][^)\]]*\b(remaster(ed)?|deluxe|expanded|anniversary|bonus|explicit|edition)\b[^)\]]*[)\]]', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+-\s+(\d{4}\s+)?remaster(ed)?(\s+\d{4})?$', caseSensitive: false), '')
      .trim();

  /// "SZA & Kendrick Lamar", "Drake feat. Future" → the first name.
  static String primaryArtist(String value) {
    final first = value
        .split(RegExp(r'\s+(feat\.?|ft\.?|featuring|with)\s+|\s*,\s*|\s+&\s+', caseSensitive: false))
        .first
        .trim();
    return first.isEmpty ? value.trim() : first;
  }

  /// Key for "the same song by the same artist" across sources.
  static String songKey(String artist, String title) => '${squash(primaryArtist(artist))}|${squash(cleanTitle(title))}';

  /// Key for "the same release by the same artist" across sources.
  static String albumKey(String artist, String title) => '${squash(primaryArtist(artist))}|${squash(cleanTitle(title))}';

  /// Optimal string alignment distance (Levenshtein plus swapped neighbours, "teh" → "the").
  static int distance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final rows = List.generate(a.length + 1, (i) => List<int>.filled(b.length + 1, 0));
    for (var i = 0; i <= a.length; i++) {
      rows[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      rows[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var value = min(min(rows[i - 1][j] + 1, rows[i][j - 1] + 1), rows[i - 1][j - 1] + cost);
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
          value = min(value, rows[i - 2][j - 2] + 1);
        }
        rows[i][j] = value;
      }
    }
    return rows[a.length][b.length];
  }
}
