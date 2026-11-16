import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'music_keys.dart';

/// MusicBrainz is too busy right now (rate limited, or not answering). Not the same as "it
/// isn't there": try again in a bit.
class MusicBrainzBusy extends http.ClientException {
  MusicBrainzBusy(Uri uri) : super('MusicBrainz is busy', uri);
}

/// A recording (a song) from MusicBrainz's search, with the releases it's on.
class MbRecording {
  const MbRecording({
    required this.id,
    required this.title,
    required this.artistName,
    this.artistMbid,
    this.isrcs = const [],
    this.length,
    this.score = 0,
    this.releases = const [],
  });

  final String id;
  final String title;
  final String artistName;
  final String? artistMbid;
  final List<String> isrcs;
  final Duration? length;

  /// MusicBrainz's own match score, 0..100.
  final int score;
  final List<MbRelease> releases;
}

/// One release (an edition) and the release group (the album or single) it belongs to.
class MbRelease {
  const MbRelease({
    required this.id,
    required this.title,
    required this.releaseGroupMbid,
    required this.releaseGroupTitle,
    this.primaryType,
    this.secondaryTypes = const [],
    this.date,
    this.official = true,
    this.barcode,
    this.artistName,
  });

  final String id;
  final String title;
  final String releaseGroupMbid;
  final String releaseGroupTitle;

  /// Album, Single, EP…
  final String? primaryType;

  /// Compilation, Live, Remix, Soundtrack…
  final List<String> secondaryTypes;
  final String? date;
  final bool official;
  final String? barcode;
  final String? artistName;

  /// A studio album, EP or single of the artist's own (not a compilation, live record or remix).
  bool get isOriginal => secondaryTypes.isEmpty;
}

/// Atlas: MusicBrainz's web service, straight from the device. This is where requests get their
/// release group id, so we go by codes first (a UPC names one product, an ISRC one recording)
/// and by names only last, with every name quoted so Lucene never sees punctuation as syntax.
///
/// MusicBrainz allows about one request a second per address, and the whole house shares one,
/// so calls queue up a little over a second apart. Answers are cached for the session.
abstract final class MusicBrainz {
  static const _base = 'musicbrainz.org';
  static const _spacing = Duration(milliseconds: 1100);
  static final Map<String, Future<Object?>> _cache = {};
  static Future<void> _queue = Future.value();
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<Object?> _get(String path, Map<String, String> query) {
    final uri = Uri.https(_base, '/ws/2$path', {...query, 'fmt': 'json'});
    return _cache.putIfAbsent(uri.toString(), () async {
      try {
        // MusicBrainz turns away bursts with 503 (the house shares one allowance with Allseerr,
        // which talks to it too), so a busy answer is waited out and tried again, not a miss.
        for (var attempt = 1; ; attempt++) {
          try {
            return await _throttled(() async {
              final response = await http
                  .get(uri, headers: {'User-Agent': MusicKeys.musicBrainzUserAgent, 'Accept': 'application/json'})
                  .timeout(const Duration(seconds: 15));
              if (response.statusCode == 404) return null;
              if (response.statusCode == 503 || response.statusCode == 429) throw MusicBrainzBusy(uri);
              if (response.statusCode != 200) throw http.ClientException('MusicBrainz ${response.statusCode}', uri);
              return jsonDecode(utf8.decode(response.bodyBytes));
            });
          } on MusicBrainzBusy {
            if (attempt >= 4) rethrow;
          } on TimeoutException {
            if (attempt >= 3) throw MusicBrainzBusy(uri);
          } on http.ClientException catch (error) {
            if (error is MusicBrainzBusy || attempt >= 3 || error.message.startsWith('MusicBrainz ')) rethrow;
          }
          await Future<void>.delayed(Duration(milliseconds: 1500 * attempt));
        }
      } catch (_) {
        _cache.remove(uri.toString());
        rethrow;
      }
    });
  }

  static Future<T> _throttled<T>(Future<T> Function() call) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      final wait = _spacing - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _last = DateTime.now();
      try {
        completer.complete(await call());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  // ---- Lucene: everything we send is quoted or stripped, never raw.

  static const _special = r'+-&|!(){}[]^"~*?:\/';

  /// [value] safe inside a quoted Lucene phrase.
  static String phrase(String value) => '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// Words of [value] with Lucene's operators taken out.
  static List<String> words(String value) {
    final buffer = StringBuffer();
    for (final char in value.split('')) {
      buffer.write(_special.contains(char) ? ' ' : char);
    }
    return buffer.toString().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  }

  // ---- Search.

  /// Songs whose title or artist matches [query], with a one-letter slip allowed in longer
  /// words (MusicBrainz's search is exact-word otherwise).
  static Future<List<MbRecording>> searchRecordings(String query, {int limit = 25}) async {
    final terms = [
      for (final word in words(query).take(8))
        if (word.length >= 4) '($word OR $word~1)' else word,
    ];
    if (terms.isEmpty) return const [];
    final joined = terms.join(' ');
    final json = await _get('/recording', {'query': 'recording:($joined) OR artist:($joined)', 'limit': '$limit'});
    final list = json is Map ? json['recordings'] : null;
    return [
      if (list is List)
        for (final entry in list) ?_recording(entry),
    ];
  }

  /// The release groups an ISRC's recording is on.
  static Future<List<MbRelease>> releasesForIsrc(String isrc) async {
    final json = await _get('/isrc/${Uri.encodeComponent(isrc.toUpperCase())}', {'inc': 'releases+release-groups+artist-credits'});
    final list = json is Map ? json['recordings'] : null;
    return [
      if (list is List)
        for (final recording in list)
          if (recording is Map) ..._releases(recording['releases'], artist: _artist(recording).$1),
    ];
  }

  /// The release with this barcode (UPC/EAN), as a release group.
  static Future<List<MbRelease>> releasesForBarcode(String barcode) async {
    final digits = barcode.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 8) return const [];
    // Deezer drops leading zeros sometimes; MusicBrainz keeps 12 (UPC) or 13 (EAN) digits.
    final variants = {digits, digits.padLeft(12, '0'), digits.padLeft(13, '0')};
    final json = await _get('/release', {
      'query': variants.map((code) => 'barcode:$code').join(' OR '),
      'limit': '5',
    });
    return _releases(json is Map ? json['releases'] : null);
  }

  /// The release group a release belongs to.
  static Future<MbRelease?> release(String releaseMbid) async {
    final json = await _get('/release/$releaseMbid', {'inc': 'release-groups+artist-credits'});
    final found = _releases(json is Map ? [json] : null);
    return found.isEmpty ? null : found.first;
  }

  /// Release groups titled [title] by [artist], exact phrases only.
  static Future<List<MbRelease>> releaseGroups(String artist, String title) async {
    if (title.trim().isEmpty) return const [];
    final query = artist.trim().isEmpty
        ? 'releasegroup:${phrase(title)}'
        : 'releasegroup:${phrase(title)} AND artist:${phrase(artist)}';
    final json = await _get('/release-group', {'query': query, 'limit': '15'});
    final list = json is Map ? json['release-groups'] : null;
    return [
      if (list is List)
        for (final group in list)
          if (group is Map && group['id'] is String && group['title'] is String)
            MbRelease(
              id: '',
              title: group['title'] as String,
              releaseGroupMbid: group['id'] as String,
              releaseGroupTitle: group['title'] as String,
              primaryType: group['primary-type'] as String?,
              secondaryTypes: [
                for (final type in (group['secondary-types'] as List?) ?? const []) ?(type is String ? type : null),
              ],
              date: group['first-release-date'] as String?,
              artistName: _artistCredit(group['artist-credit']).$1,
            ),
    ];
  }

  /// The MusicBrainz id of the artist named exactly [name] (the best scored one).
  static Future<String?> artistId(String name) async {
    final json = await _get('/artist', {'query': 'artist:${phrase(name)}', 'limit': '5'});
    final list = json is Map ? json['artists'] : null;
    if (list is! List) return null;
    final want = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    for (final artist in list) {
      if (artist is! Map || artist['id'] is! String) continue;
      final got = '${artist['name'] ?? ''}'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
      if (got == want && ((artist['score'] as num?) ?? 0) >= 90) return artist['id'] as String;
    }
    return null;
  }

  /// Every album, EP and single release group of an artist (up to 300).
  static Future<List<MbRelease>> releaseGroupsOf(String artistMbid) async {
    final groups = <MbRelease>[];
    for (var offset = 0; offset < 300; offset += 100) {
      final json = await _get('/release-group', {
        'artist': artistMbid,
        'type': 'album|ep|single',
        'limit': '100',
        'offset': '$offset',
      });
      final list = json is Map ? json['release-groups'] : null;
      if (list is! List || list.isEmpty) break;
      for (final group in list) {
        if (group is! Map || group['id'] is! String || group['title'] is! String) continue;
        groups.add(
          MbRelease(
            id: '',
            title: group['title'] as String,
            releaseGroupMbid: group['id'] as String,
            releaseGroupTitle: group['title'] as String,
            primaryType: group['primary-type'] as String?,
            secondaryTypes: [
              for (final type in (group['secondary-types'] as List?) ?? const []) ?(type is String ? type : null),
            ],
            date: group['first-release-date'] as String?,
          ),
        );
      }
      final total = (json as Map)['release-group-count'];
      if (total is num && groups.length >= total) break;
    }
    return groups;
  }

  // ---- Parsing.

  static MbRecording? _recording(Object? json) {
    if (json is! Map || json['id'] is! String || json['title'] is! String) return null;
    final (artist, artistMbid) = _artist(json);
    final length = json['length'];
    return MbRecording(
      id: json['id'] as String,
      title: json['title'] as String,
      artistName: artist ?? '',
      artistMbid: artistMbid,
      isrcs: [for (final isrc in (json['isrcs'] as List?) ?? const []) ?(isrc is String ? isrc : null)],
      length: length is num ? Duration(milliseconds: length.toInt()) : null,
      score: (json['score'] as num?)?.toInt() ?? 0,
      releases: _releases(json['releases'], artist: artist),
    );
  }

  static (String?, String?) _artist(Map json) => _artistCredit(json['artist-credit']);

  /// The credited name ("SZA & Kendrick Lamar") and the first artist's id.
  static (String?, String?) _artistCredit(Object? credit) {
    if (credit is! List || credit.isEmpty) return (null, null);
    final name = StringBuffer();
    String? id;
    for (final part in credit) {
      if (part is! Map) continue;
      final artist = part['artist'];
      name
        ..write(part['name'] ?? (artist is Map ? artist['name'] : '') ?? '')
        ..write(part['joinphrase'] ?? '');
      if (id == null && artist is Map && artist['id'] is String) id = artist['id'] as String;
    }
    final text = name.toString().trim();
    return (text.isEmpty ? null : text, id);
  }

  static List<MbRelease> _releases(Object? list, {String? artist}) {
    if (list is! List) return const [];
    final releases = <MbRelease>[];
    for (final json in list) {
      if (json is! Map || json['id'] is! String) continue;
      final group = json['release-group'];
      if (group is! Map || group['id'] is! String) continue;
      releases.add(
        MbRelease(
          id: json['id'] as String,
          title: json['title'] as String? ?? '',
          releaseGroupMbid: group['id'] as String,
          releaseGroupTitle: group['title'] as String? ?? json['title'] as String? ?? '',
          primaryType: group['primary-type'] as String?,
          secondaryTypes: [
            for (final type in (group['secondary-types'] as List?) ?? const []) ?(type is String ? type : null),
          ],
          date: json['date'] as String?,
          official: (json['status'] as String?)?.toLowerCase() != 'bootleg',
          barcode: json['barcode'] as String?,
          artistName: _artistCredit(json['artist-credit']).$1 ?? artist,
        ),
      );
    }
    return releases;
  }
}
