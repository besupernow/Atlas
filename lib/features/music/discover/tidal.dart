import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'music_keys.dart';

/// A song from TIDAL: its ISRC, how popular it is (0..1), everyone credited, and its album.
class TidalTrack {
  const TidalTrack({
    required this.id,
    required this.title,
    required this.artists,
    this.isrc,
    this.length,
    this.popularity = 0,
    this.album,
  });

  final String id;
  final String title;

  /// Main artist first, then anyone featured.
  final List<String> artists;
  final String? isrc;
  final Duration? length;
  final double popularity;
  final TidalAlbum? album;
}

/// An album, EP or single from TIDAL, with its barcode (UPC).
class TidalAlbum {
  const TidalAlbum({
    required this.id,
    required this.title,
    required this.artists,
    this.barcode,
    this.type,
    this.releaseDate,
    this.popularity = 0,
    this.coverUrl,
  });

  final String id;
  final String title;
  final List<String> artists;
  final String? barcode;

  /// Album, EP or Single.
  final String? type;
  final String? releaseDate;
  final double popularity;
  final String? coverUrl;
}

class TidalArtist {
  const TidalArtist({required this.id, required this.name, this.popularity = 0});

  final String id;
  final String name;
  final double popularity;
}

class TidalSearchResults {
  const TidalSearchResults({this.tracks = const [], this.albums = const [], this.artists = const []});

  static const empty = TidalSearchResults();

  final List<TidalTrack> tracks;
  final List<TidalAlbum> albums;
  final List<TidalArtist> artists;
}

/// Atlas: TIDAL's public catalog API (openapi.tidal.com, v2), signed in as the app with client
/// credentials, so there's no person behind the token and nothing personal in the answers.
/// TIDAL has what the others are missing in one place: a popularity score on every song,
/// album and artist, full artist credits (features included), ISRCs on songs and barcodes on
/// albums (which is how a request finds the exact MusicBrainz release). It's also where Lidarr
/// gets music from here (Tidarr), so what TIDAL lists is what can actually be downloaded.
abstract final class Tidal {
  static bool get isConfigured => MusicKeys.tidalClientId.isNotEmpty && MusicKeys.tidalClientSecret.isNotEmpty;

  static const _country = 'US';
  static String? _token;
  static DateTime _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<String>? _tokenLoading;
  static final Map<String, Future<Object?>> _cache = {};

  static Future<String> _accessToken() {
    final token = _token;
    if (token != null && DateTime.now().isBefore(_tokenExpires)) return Future.value(token);
    return _tokenLoading ??= () async {
      try {
        final basic = base64Encode(utf8.encode('${MusicKeys.tidalClientId}:${MusicKeys.tidalClientSecret}'));
        final response = await http
            .post(
              Uri.https('auth.tidal.com', '/v1/oauth2/token'),
              headers: {'Authorization': 'Basic $basic', 'Content-Type': 'application/x-www-form-urlencoded'},
              body: 'grant_type=client_credentials',
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) throw http.ClientException('TIDAL sign-in ${response.statusCode}');
        final data = jsonDecode(response.body);
        final value = data is Map ? data['access_token'] : null;
        if (value is! String) throw http.ClientException('TIDAL sign-in gave no token');
        final seconds = data is Map && data['expires_in'] is num ? (data['expires_in'] as num).toInt() : 3600;
        _token = value;
        _tokenExpires = DateTime.now().add(Duration(seconds: seconds - 60));
        return value;
      } finally {
        _tokenLoading = null;
      }
    }();
  }

  static Future<Object?> _get(List<String> path, Map<String, String> query) {
    if (!isConfigured) return Future.value();
    final uri = Uri(
      scheme: 'https',
      host: 'openapi.tidal.com',
      pathSegments: ['v2', ...path],
      queryParameters: {'countryCode': _country, ...query},
    );
    return _cache.putIfAbsent(uri.toString(), () async {
      try {
        for (var attempt = 1; ; attempt++) {
          final response = await http
              .get(uri, headers: {'Authorization': 'Bearer ${await _accessToken()}', 'Accept': 'application/vnd.api+json'})
              .timeout(const Duration(seconds: 12));
          if (response.statusCode == 401 && attempt == 1) {
            _token = null; // Expired early: sign in again once.
            continue;
          }
          if (response.statusCode == 429 && attempt < 3) {
            await Future<void>.delayed(Duration(milliseconds: 800 * attempt));
            continue;
          }
          if (response.statusCode == 404) return null;
          if (response.statusCode != 200) throw http.ClientException('TIDAL ${response.statusCode}', uri);
          return jsonDecode(utf8.decode(response.bodyBytes));
        }
      } catch (_) {
        _cache.remove(uri.toString());
        rethrow;
      }
    });
  }

  /// Songs, albums and artists for [query], in TIDAL's order, with full details.
  static Future<TidalSearchResults> search(String query) async {
    if (!isConfigured || query.trim().isEmpty) return TidalSearchResults.empty;
    final json = await _get(['searchResults', query.trim()], {'include': 'tracks,albums,artists'});
    final relationships = _relationships(json is Map ? json['data'] : null);
    List<String> ids(String name) => [
      for (final ref in _refs(relationships[name])) ref.$2,
    ];
    final trackIds = ids('tracks').take(20).toList();
    final albumIds = ids('albums').take(20).toList();
    final artistIds = ids('artists').take(15).toList();
    final results = await Future.wait<Object?>([
      if (trackIds.isEmpty) Future.value() else _get(['tracks'], {'filter[id]': trackIds.join(','), 'include': 'artists,albums'}),
      if (albumIds.isEmpty) Future.value() else _get(['albums'], {'filter[id]': albumIds.join(','), 'include': 'artists,coverArt'}),
    ]);
    final searchIndex = _included(json);
    final tracks = _tracks(results[0], order: trackIds);
    final albums = _albums(results[1], order: albumIds);
    final artists = [
      for (final id in artistIds)
        if (searchIndex['artists:$id'] case final artist?) ?_artist(artist),
    ];
    return TidalSearchResults(tracks: tracks, albums: albums, artists: artists);
  }

  /// Albums with this barcode (to fill in a UPC-less album's details, or check one).
  static Future<List<TidalAlbum>> albumsByBarcode(String barcode) async {
    final json = await _get(['albums'], {'filter[barcodeId]': barcode, 'include': 'artists,coverArt'});
    return _albums(json);
  }

  // ---- JSON:API parsing.

  static Map _relationships(Object? resource) {
    final relationships = resource is Map ? resource['relationships'] : null;
    return relationships is Map ? relationships : const {};
  }

  /// (type, id) pairs of a relationship.
  static List<(String, String)> _refs(Object? relationship) {
    final data = relationship is Map ? relationship['data'] : null;
    final list = data is List ? data : (data is Map ? [data] : const []);
    return [
      for (final ref in list)
        if (ref is Map && ref['id'] != null && ref['type'] is String) (ref['type'] as String, '${ref['id']}'),
    ];
  }

  /// Every resource in a response (the main data and `included`), by "type:id".
  static Map<String, Map> _included(Object? json) {
    final index = <String, Map>{};
    if (json is! Map) return index;
    for (final key in const ['data', 'included']) {
      final value = json[key];
      final list = value is List ? value : (value is Map ? [value] : const []);
      for (final resource in list) {
        if (resource is Map && resource['type'] is String && resource['id'] != null) {
          index['${resource['type']}:${resource['id']}'] = resource;
        }
      }
    }
    return index;
  }

  static Map _attributes(Map resource) {
    final attributes = resource['attributes'];
    return attributes is Map ? attributes : const {};
  }

  static List<String> _artistNames(Map resource, Map<String, Map> index) => [
    for (final (type, id) in _refs(_relationships(resource)['artists']))
      if (index['$type:$id'] case final artist?)
        if (_attributes(artist)['name'] case final String name when name.isNotEmpty) name,
  ];

  static List<TidalTrack> _tracks(Object? json, {required List<String> order}) {
    final index = _included(json);
    final tracks = <TidalTrack>[];
    for (final id in order) {
      final resource = index['tracks:$id'];
      if (resource == null) continue;
      final attributes = _attributes(resource);
      final title = attributes['title'];
      if (title is! String) continue;
      final version = attributes['version'];
      final albumRef = _refs(_relationships(resource)['albums']).firstOrNull;
      final albumResource = albumRef == null ? null : index['${albumRef.$1}:${albumRef.$2}'];
      tracks.add(
        TidalTrack(
          id: id,
          title: version is String && version.isNotEmpty && !title.contains(version) ? '$title ($version)' : title,
          artists: _artistNames(resource, index),
          isrc: _string(attributes['isrc']),
          length: _duration(attributes['duration']),
          popularity: _popularity(attributes['popularity']),
          album: albumResource == null ? null : _album(albumResource, index),
        ),
      );
    }
    return tracks;
  }

  static List<TidalAlbum> _albums(Object? json, {List<String>? order}) {
    final index = _included(json);
    final ids = order ??
        [
          for (final key in index.keys)
            if (key.startsWith('albums:')) key.substring('albums:'.length),
        ];
    return [
      for (final id in ids)
        if (index['albums:$id'] case final resource?) ?_album(resource, index),
    ];
  }

  static TidalAlbum? _album(Map resource, Map<String, Map> index) {
    final attributes = _attributes(resource);
    final title = attributes['title'];
    if (title is! String) return null;
    return TidalAlbum(
      id: '${resource['id']}',
      title: title,
      artists: _artistNames(resource, index),
      barcode: _string(attributes['barcodeId']),
      type: switch ('${attributes['type'] ?? ''}'.toUpperCase()) {
        'SINGLE' => 'Single',
        'EP' => 'EP',
        'ALBUM' => 'Album',
        _ => null,
      },
      releaseDate: _string(attributes['releaseDate']),
      popularity: _popularity(attributes['popularity']),
      coverUrl: _cover(resource, index),
    );
  }

  static TidalArtist? _artist(Map resource) {
    final attributes = _attributes(resource);
    final name = attributes['name'];
    if (name is! String) return null;
    return TidalArtist(id: '${resource['id']}', name: name, popularity: _popularity(attributes['popularity']));
  }

  /// The largest cover file (artworks resources carry a list of sizes).
  static String? _cover(Map album, Map<String, Map> index) {
    for (final (type, id) in _refs(_relationships(album)['coverArt'])) {
      final artwork = index['$type:$id'];
      if (artwork == null) continue;
      final files = _attributes(artwork)['files'];
      if (files is! List) continue;
      String? best;
      var bestWidth = 0;
      for (final file in files) {
        if (file is! Map || file['href'] is! String) continue;
        final meta = file['meta'];
        final width = meta is Map && meta['width'] is num ? (meta['width'] as num).toInt() : 0;
        if (best == null || (width > bestWidth && width <= 1280)) {
          best = file['href'] as String;
          bestWidth = width;
        }
      }
      if (best != null) return best;
    }
    return null;
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

  static double _popularity(Object? value) => value is num ? value.toDouble().clamp(0.0, 1.0) : 0.0;

  /// ISO 8601 durations ("PT3M25S").
  static Duration? _duration(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'^P(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$').firstMatch(value);
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = double.tryParse(match.group(3) ?? '') ?? 0;
    return Duration(hours: hours, minutes: minutes, milliseconds: (seconds * 1000).round());
  }
}
