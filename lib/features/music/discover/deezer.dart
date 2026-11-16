import 'dart:convert';

import 'package:http/http.dart' as http;

import 'discover_models.dart';

/// A song on a chart.
class ChartTrack {
  const ChartTrack({
    required this.id,
    required this.rank,
    required this.title,
    required this.artistName,
    required this.album,
    this.previewUrl,
    this.length,
  });

  final int id;
  final int rank;
  final String title;
  final String artistName;
  final DiscoverAlbum album;
  final String? previewUrl;
  final Duration? length;

  /// Key for the preview player.
  String get previewKey => 'dz-track:$id';
}

/// What the request sheet shows from Deezer about an album.
class DeezerAlbumDetails {
  const DeezerAlbumDetails({
    required this.album,
    required this.tracks,
    this.genres = const [],
    this.label,
    this.fans,
  });

  final DiscoverAlbum album;
  final List<DiscoverTrack> tracks;
  final List<String> genres;
  final String? label;
  final int? fans;
}

/// Atlas: Deezer's public catalog (no account, no key): what's charting right now, the
/// editors' new releases, big artwork, full track lists with 30-second previews, and related
/// artists. Music mode leans on it for New and for discovery, where MusicBrainz metadata is thin;
/// Allseerr stays the way requests reach Lidarr.
abstract final class Deezer {
  static const _headers = {'User-Agent': 'Atlas/1.0', 'Accept': 'application/json'};
  static final Map<String, Future<Object?>> _cache = {};

  static Future<Object?> _get(String path, [Map<String, String>? query]) {
    final uri = Uri.https('api.deezer.com', path, query);
    return _cache.putIfAbsent(uri.toString(), () async {
      try {
        final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 12));
        if (response.statusCode != 200) throw http.ClientException('Deezer ${response.statusCode}', uri);
        final data = jsonDecode(response.body);
        if (data is Map && data['error'] != null) throw http.ClientException('Deezer: ${data['error']}', uri);
        return data;
      } catch (_) {
        _cache.remove(uri.toString());
        rethrow;
      }
    });
  }

  /// Forget cached answers (pull to refresh).
  static void clearCache() => _cache.clear();

  static List<Map> _data(Object? json) {
    final data = json is Map ? json['data'] : null;
    return data is List ? data.whereType<Map>().toList() : const [];
  }

  static String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

  static DiscoverArtist? artistFrom(Object? json, {String? reason}) {
    if (json is! Map || json['id'] is! num) return null;
    final id = (json['id'] as num).toInt();
    final name = _string(json['name']);
    if (name == null) return null;
    final picture = _string(json['picture_xl']) ?? _string(json['picture_big']);
    // Deezer's stand-in for "no picture" is a grey silhouette; leave those blank.
    final image = picture != null && picture.contains('/artist//') ? null : picture;
    return DiscoverArtist(mbid: 'dz:$id', deezerId: id, name: name, imageUrl: image, backdropUrl: image, reason: reason);
  }

  static DiscoverAlbum? albumFrom(Object? json, {Object? artist, String? reason}) {
    if (json is! Map || json['id'] is! num) return null;
    final id = (json['id'] as num).toInt();
    final title = _string(json['title']);
    if (title == null) return null;
    final artistJson = json['artist'] ?? artist;
    final artistName = artistJson is Map ? _string(artistJson['name']) : null;
    return DiscoverAlbum(
      mbid: 'dz:$id',
      deezerId: id,
      title: title,
      artistName: artistName ?? '',
      coverUrl: _string(json['cover_xl']) ?? _string(json['cover_big']),
      releaseDate: _string(json['release_date']),
      type: switch (json['record_type']) {
        'single' => 'Single',
        'ep' => 'EP',
        'compile' => 'Compilation',
        'album' => 'Album',
        _ => null,
      },
      reason: reason,
    );
  }

  /// The editors' pick of new releases (this week and last), overall or in one [genre].
  static Future<List<DiscoverAlbum>> newReleases({int limit = 60, int genre = 0}) async => [
    for (final json in _data(await _get('/editorial/$genre/releases', {'limit': '$limit'}))) ?albumFrom(json),
  ];

  /// The most played albums right now, overall or in one [genre].
  static Future<List<DiscoverAlbum>> topAlbums({int limit = 50, int genre = 0}) async => [
    for (final json in _data(await _get('/chart/$genre/albums', {'limit': '$limit'}))) ?albumFrom(json),
  ];

  /// The most played artists right now.
  static Future<List<DiscoverArtist>> topArtists({int limit = 30}) async => [
    for (final json in _data(await _get('/chart/0/artists', {'limit': '$limit'}))) ?artistFrom(json),
  ];

  /// The most played songs right now.
  static Future<List<ChartTrack>> topTracks({int limit = 50}) async {
    final tracks = <ChartTrack>[];
    for (final json in _data(await _get('/chart/0/tracks', {'limit': '$limit'}))) {
      final album = albumFrom(json['album'], artist: json['artist']);
      final id = json['id'];
      if (album == null || id is! num) continue;
      tracks.add(
        ChartTrack(
          id: id.toInt(),
          rank: (json['position'] as num?)?.toInt() ?? tracks.length + 1,
          title: _string(json['title_short']) ?? _string(json['title']) ?? '',
          artistName: album.artistName,
          album: album,
          previewUrl: _string(json['preview']),
          length: json['duration'] is num ? Duration(seconds: (json['duration'] as num).toInt()) : null,
        ),
      );
    }
    return tracks;
  }

  /// The best match for an artist by name.
  static Future<DiscoverArtist?> findArtist(String name) async {
    final results = _data(await _get('/search/artist', {'q': name, 'limit': '5'}));
    final want = normal(name);
    for (final json in results) {
      if (normal(json['name'] as String? ?? '') == want) return artistFrom(json);
    }
    return results.isEmpty ? null : artistFrom(results.first);
  }

  /// The best match for an album by artist and title.
  static Future<DiscoverAlbum?> findAlbum(String artist, String title) async {
    final query = 'artist:"${artist.replaceAll('"', '')}" album:"${title.replaceAll('"', '')}"';
    final results = _data(await _get('/search/album', {'q': query, 'limit': '10'}));
    final wantTitle = normal(title);
    final wantArtist = normal(artist);
    DiscoverAlbum? loose;
    for (final json in results) {
      final album = albumFrom(json);
      if (album == null) continue;
      final gotArtist = normal(album.artistName);
      if (!(gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist))) continue;
      final gotTitle = normal(album.title);
      if (gotTitle == wantTitle) return album;
      if (gotTitle.startsWith(wantTitle) || wantTitle.startsWith(gotTitle)) loose ??= album;
    }
    return loose;
  }

  /// Artists like [artist].
  static Future<List<DiscoverArtist>> related(DiscoverArtist artist, {int limit = 20, String? reason}) async {
    final id = artist.deezerId ?? (await findArtist(artist.name))?.deezerId;
    if (id == null) return const [];
    return [
      for (final json in _data(await _get('/artist/$id/related', {'limit': '$limit'}))) ?artistFrom(json, reason: reason),
    ];
  }

  /// An artist's releases, newest first.
  static Future<List<DiscoverAlbum>> albumsBy(DiscoverArtist artist) async {
    final id = artist.deezerId ?? (await findArtist(artist.name))?.deezerId;
    if (id == null) return const [];
    final albums = [
      for (final json in _data(await _get('/artist/$id/albums', {'limit': '100'})))
        ?albumFrom(json, artist: {'name': artist.name}),
    ];
    albums.sort((a, b) => (b.releaseDate ?? '').compareTo(a.releaseDate ?? ''));
    return albums;
  }

  /// An artist's most played songs, with previews.
  static Future<List<ChartTrack>> topTracksOf(DiscoverArtist artist, {int limit = 15}) async {
    final id = artist.deezerId ?? (await findArtist(artist.name))?.deezerId;
    if (id == null) return const [];
    final tracks = <ChartTrack>[];
    for (final json in _data(await _get('/artist/$id/top', {'limit': '$limit'}))) {
      final album = albumFrom(json['album'], artist: json['artist'] ?? {'name': artist.name});
      final trackId = json['id'];
      if (album == null || trackId is! num) continue;
      tracks.add(
        ChartTrack(
          id: trackId.toInt(),
          rank: tracks.length + 1,
          title: _string(json['title_short']) ?? _string(json['title']) ?? '',
          artistName: album.artistName,
          album: album.copyWith(ids: MusicIds(deezerTrackId: trackId.toInt(), isrc: _string(json['isrc']))),
          previewUrl: _string(json['preview']),
          length: json['duration'] is num ? Duration(seconds: (json['duration'] as num).toInt()) : null,
        ),
      );
    }
    return tracks;
  }

  /// The album an artist is best known for (the album of their most played song).
  static Future<DiscoverAlbum?> signatureAlbum(DiscoverArtist artist, {String? reason}) async {
    final id = artist.deezerId ?? (await findArtist(artist.name))?.deezerId;
    if (id == null) return null;
    for (final json in _data(await _get('/artist/$id/top', {'limit': '5'}))) {
      final album = albumFrom(json['album'], artist: json['artist'] ?? {'name': artist.name}, reason: reason);
      if (album != null) return album;
    }
    return null;
  }

  /// Track list (with previews), genres and label for [album]: by its Deezer id, or found by
  /// artist and title.
  static Future<DeezerAlbumDetails?> details(DiscoverAlbum album) async {
    final id = album.deezerId ?? (await findAlbum(album.artistName, album.title))?.deezerId;
    if (id == null) return null;
    final results = await Future.wait([_get('/album/$id'), _get('/album/$id/tracks', {'limit': '200'})]);
    final info = results[0];
    if (info is! Map) return null;
    final found = albumFrom(info);
    final genres = info['genres'] is Map ? _data(info['genres']) : const <Map>[];
    return DeezerAlbumDetails(
      album: album.copyWith(deezerId: id, coverUrl: found?.coverUrl),
      genres: [for (final genre in genres) ?_string(genre['name'])],
      label: _string(info['label']),
      fans: (info['fans'] as num?)?.toInt(),
      tracks: [
        for (final (index, track) in _data(results[1]).indexed)
          DiscoverTrack(
            title: _string(track['title_short']) ?? _string(track['title']) ?? '',
            number: '${(track['track_position'] as num?)?.toInt() ?? index + 1}',
            disc: (track['disk_number'] as num?)?.toInt() ?? 1,
            length: track['duration'] is num ? Duration(seconds: (track['duration'] as num).toInt()) : null,
            artist: track['artist'] is Map ? _string(track['artist']['name']) : null,
            previewUrl: _string(track['preview']),
            isrc: _string(track['isrc']),
            deezerId: (track['id'] as num?)?.toInt(),
          ),
      ],
    );
  }

  /// Deezer's search for [kind] (track, album or artist), raw entries in Deezer's order.
  static Future<List<Map>> search(String kind, String query, {int limit = 25}) async =>
      _data(await _get('/search/$kind', {'q': query, 'limit': '$limit'}));

  // ---- Standard codes, for tying Deezer's albums and songs to MusicBrainz.

  /// The barcode (UPC/EAN) of a Deezer album.
  static Future<String?> upcOf(int albumId) async {
    final info = await _get('/album/$albumId');
    return info is Map ? _string(info['upc']) : null;
  }

  /// The ISRC of a Deezer track.
  static Future<String?> isrcOf(int trackId) async {
    final info = await _get('/track/$trackId');
    return info is Map ? _string(info['isrc']) : null;
  }

  /// A song's ISRC found by artist and title (exact title, artist contained).
  static Future<String?> findIsrc(String artist, String title) async {
    final query = 'artist:"${artist.replaceAll('"', '')}" track:"${title.replaceAll('"', '')}"';
    final wantTitle = normal(title);
    final wantArtist = normal(artist);
    for (final json in _data(await _get('/search/track', {'q': query, 'limit': '10'}))) {
      final gotTitle = normal(_string(json['title_short']) ?? _string(json['title']) ?? '');
      final artistJson = json['artist'];
      final gotArtist = normal(artistJson is Map ? _string(artistJson['name']) ?? '' : '');
      if (gotTitle != wantTitle || !(gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist))) continue;
      final id = json['id'];
      if (id is num) return isrcOf(id.toInt());
    }
    return null;
  }

  /// ISRCs of a Deezer album's first few tracks.
  static Future<List<String>> albumIsrcs(int albumId, {int count = 2}) async {
    final tracks = _data(await _get('/album/$albumId/tracks', {'limit': '200'}));
    final isrcs = <String>[];
    for (final track in tracks.take(count)) {
      final isrc = _string(track['isrc']) ?? (track['id'] is num ? await isrcOf((track['id'] as num).toInt()) : null);
      if (isrc != null) isrcs.add(isrc);
    }
    return isrcs;
  }

  static String normal(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\((deluxe|expanded|remaster|anniversary|bonus|explicit)[^)]*\)|\[[^\]]*\]'), '')
      .replaceAll('&', 'and')
      .replaceAll(RegExp(r'^the '), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

/// A Deezer genre (its id works for charts and editorial releases).
class MusicGenreChannel {
  const MusicGenreChannel(this.id, this.name, this.keywords);

  final int id;
  final String name;

  /// Words in a library genre that mean this one.
  final List<String> keywords;

  static const all = [
    MusicGenreChannel(132, 'Pop', ['pop']),
    MusicGenreChannel(116, 'Hip-Hop', ['hip hop', 'hip-hop', 'hiphop', 'rap', 'trap', 'drill']),
    MusicGenreChannel(165, 'R&B', ['r&b', 'rnb', 'r and b', 'rhythm']),
    MusicGenreChannel(152, 'Rock', ['rock', 'punk', 'grunge']),
    MusicGenreChannel(85, 'Alternative', ['alternative', 'indie', 'alt']),
    MusicGenreChannel(113, 'Dance', ['dance', 'house', 'edm', 'disco']),
    MusicGenreChannel(106, 'Electronic', ['electronic', 'electro', 'techno', 'trance', 'dubstep', 'synth']),
    MusicGenreChannel(197, 'Latin', ['latin', 'reggaeton', 'salsa', 'bachata']),
    MusicGenreChannel(16, 'K-Pop & Asian', ['k-pop', 'kpop', 'j-pop', 'jpop', 'anime', 'asian', 'korean', 'japanese']),
    MusicGenreChannel(84, 'Country', ['country', 'americana']),
    MusicGenreChannel(466, 'Folk', ['folk', 'acoustic', 'singer-songwriter', 'singer/songwriter']),
    MusicGenreChannel(169, 'Soul & Funk', ['soul', 'funk', 'motown']),
    MusicGenreChannel(464, 'Metal', ['metal', 'metalcore', 'hardcore']),
    MusicGenreChannel(129, 'Jazz', ['jazz', 'swing', 'bebop']),
    MusicGenreChannel(173, 'Soundtracks', ['soundtrack', 'score', 'film', 'musical', 'game']),
    MusicGenreChannel(144, 'Reggae', ['reggae', 'dancehall', 'ska']),
    MusicGenreChannel(98, 'Classical', ['classical', 'orchestral', 'opera', 'baroque']),
    MusicGenreChannel(153, 'Blues', ['blues']),
  ];

  /// The genres this person leans toward, from how many albums in their library carry each
  /// genre name, then the popular ones.
  static List<MusicGenreChannel> rank(Map<String, int> libraryGenreCounts) {
    final scores = <MusicGenreChannel, int>{};
    for (final MapEntry(key: name, value: count) in libraryGenreCounts.entries) {
      final lower = name.toLowerCase();
      for (final channel in all) {
        if (channel.keywords.any(lower.contains)) {
          scores[channel] = (scores[channel] ?? 0) + count;
          break;
        }
      }
    }
    final ranked = scores.keys.toList()..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    return [...ranked, for (final channel in all) if (!ranked.contains(channel)) channel];
  }
}

