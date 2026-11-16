import 'dart:convert';

import 'package:http/http.dart' as http;

import 'music_keys.dart';

/// Something Last.fm knows, with how many people listen to it (its popularity signal).
class LastFmHit {
  const LastFmHit({
    required this.name,
    this.artistName = '',
    this.mbid,
    this.artistMbid,
    this.listeners = 0,
    this.imageUrl,
  });

  final String name;
  final String artistName;

  /// For tracks a recording id, for albums a release id, for artists an artist id; Last.fm
  /// leaves it blank for plenty of things.
  final String? mbid;
  final String? artistMbid;
  final int listeners;
  final String? imageUrl;
}

/// Atlas: Last.fm's public API, for what people actually play: listener counts on songs and
/// artists (search) and what's climbing right now (charts). Needs [MusicKeys.lastFm].
abstract final class LastFm {
  static bool get isConfigured => MusicKeys.lastFm.isNotEmpty;

  static final Map<String, Future<Object?>> _cache = {};

  static Future<Object?> _get(String method, Map<String, String> params) {
    if (!isConfigured) return Future.value();
    final uri = Uri.https('ws.audioscrobbler.com', '/2.0/', {
      'method': method,
      ...params,
      'api_key': MusicKeys.lastFm,
      'format': 'json',
    });
    return _cache.putIfAbsent(uri.toString(), () async {
      try {
        final response = await http.get(uri, headers: {'User-Agent': 'Atlas/1.0'}).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) throw http.ClientException('Last.fm ${response.statusCode}', uri);
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data is Map && data['error'] != null) throw http.ClientException('Last.fm: ${data['message']}', uri);
        return data;
      } catch (_) {
        _cache.remove(uri.toString());
        rethrow;
      }
    });
  }

  /// Forget cached answers (charts move).
  static void clearCache() => _cache.clear();

  static Future<List<LastFmHit>> searchTracks(String query, {int limit = 30}) async =>
      _hits(await _get('track.search', {'track': query, 'limit': '$limit'}), ['results', 'trackmatches', 'track']);

  static Future<List<LastFmHit>> searchArtists(String query, {int limit = 20}) async =>
      _hits(await _get('artist.search', {'artist': query, 'limit': '$limit'}), ['results', 'artistmatches', 'artist']);

  static Future<List<LastFmHit>> searchAlbums(String query, {int limit = 20}) async =>
      _hits(await _get('album.search', {'album': query, 'limit': '$limit'}), ['results', 'albummatches', 'album']);

  /// The most played songs on Last.fm right now.
  static Future<List<LastFmHit>> chartTracks({int limit = 100}) async =>
      _hits(await _get('chart.getTopTracks', {'limit': '$limit'}), ['tracks', 'track']);

  /// The most played artists on Last.fm right now.
  static Future<List<LastFmHit>> chartArtists({int limit = 100}) async =>
      _hits(await _get('chart.getTopArtists', {'limit': '$limit'}), ['artists', 'artist']);

  static List<LastFmHit> _hits(Object? json, List<String> path) {
    Object? node = json;
    for (final key in path) {
      node = node is Map ? node[key] : null;
    }
    // A single match comes back as an object instead of a list.
    final list = node is List ? node : (node is Map ? [node] : const []);
    return [
      for (final entry in list)
        if (entry is Map && entry['name'] is String) _hit(entry),
    ];
  }

  static LastFmHit _hit(Map entry) {
    final artist = entry['artist'];
    return LastFmHit(
      name: entry['name'] as String,
      artistName: switch (artist) {
        final String name => name,
        final Map map => map['name'] as String? ?? '',
        _ => '',
      },
      mbid: _mbid(entry['mbid']),
      artistMbid: artist is Map ? _mbid(artist['mbid']) : null,
      listeners: int.tryParse('${entry['listeners'] ?? entry['playcount'] ?? 0}') ?? 0,
      imageUrl: _image(entry['image']),
    );
  }

  static String? _mbid(Object? value) => value is String && value.length == 36 ? value : null;

  /// The largest picture, skipping Last.fm's blank star placeholder.
  static String? _image(Object? images) {
    if (images is! List) return null;
    for (final size in const ['mega', 'extralarge', 'large']) {
      for (final image in images) {
        if (image is! Map || image['size'] != size) continue;
        final url = image['#text'];
        if (url is String && url.isNotEmpty && !url.contains('2a96cbd8b46e442fc41c2b86b821562f')) return url;
      }
    }
    return null;
  }
}
