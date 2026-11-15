import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../../media/media_item.dart';
import '../data/music_catalog.dart';
import 'allseerr_music.dart';
import 'deezer.dart';
import 'discover_feed.dart';
import 'discover_models.dart';

/// A song in search results: ours (playable) or from outside (preview, request its release).
class SearchSong {
  const SearchSong.server(MediaItem this.server, this.score) : external = null;
  const SearchSong.external(ChartTrack this.external, this.score) : server = null;

  final MediaItem? server;
  final ChartTrack? external;
  final double score;

  String get title => server?.title ?? external?.title ?? '';
  String get artist => server?.trackArtistTitle ?? server?.albumArtistTitle ?? external?.artistName ?? '';
  String? get albumTitle => server?.albumTitle ?? external?.album.title;

  String get key => '${Deezer.normal(artist)}|${Deezer.normal(title)}';
}

class MusicSearchOutcome {
  const MusicSearchOutcome({
    this.top,
    this.topSong,
    this.artists = const [],
    this.albums = const [],
    this.songs = const [],
  });

  /// The best match when it's an artist or an album…
  final MusicFeedItem? top;

  /// …or when it's a song (Apple Music puts a song on top when that's what people mean).
  final SearchSong? topSong;
  final List<MusicFeedItem> artists;
  final List<MusicFeedItem> albums;
  final List<SearchSong> songs;

  bool get isEmpty => top == null && topSong == null && artists.isEmpty && albums.isEmpty && songs.isEmpty;
}

/// Atlas: music search across the server and the world, ordered the way Apple Music orders it.
///
/// Songs and albums come in the iTunes Store's own order (Apple's relevance and popularity, the
/// same ranking the Apple Music app uses), with Deezer filling gaps. Artists come from Deezer,
/// where every artist has a fan count: candidates are scored on how close the name is AND how
/// popular they are, so "siza" finds SZA and "AJR" finds the band (also tried: spellings one
/// letter off). The top result is the artist when the query is clearly their name, otherwise
/// the song most people mean. Anything already on the server shows as ours.
class MusicSearch {
  MusicSearch(this.discovery);

  final MusicDiscovery discovery;

  static const _headers = {'User-Agent': 'Atlas/1.0', 'Accept': 'application/json'};
  static final Map<String, Future<Object?>> _cache = {};

  /// Only what's on the server (the Library tab).
  Future<MusicSearchOutcome> searchLibrary(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const MusicSearchOutcome();
    final q = Deezer.normal(query);
    final found = await discovery.catalog.search(query);
    double score(String name) => _text(q, Deezer.normal(name));
    final artists = [...found.artists]..sort((a, b) => score(b.title ?? '').compareTo(score(a.title ?? '')));
    final albums = [...found.albums]..sort(
      (a, b) => max(score(b.title ?? ''), score(b.albumArtistTitle ?? '') * 0.9)
          .compareTo(max(score(a.title ?? ''), score(a.albumArtistTitle ?? '') * 0.9)),
    );
    final songs = [
      for (final track in found.songs)
        SearchSong.server(track, max(score(track.title ?? ''), score(track.trackArtistTitle ?? '') * 0.9)),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final topArtist = artists.isNotEmpty && score(artists.first.title ?? '') >= 0.9 ? artists.first : null;
    return MusicSearchOutcome(
      top: topArtist != null ? ServerFeedItem(topArtist) : null,
      topSong: topArtist == null && songs.isNotEmpty ? songs.first : null,
      artists: [for (final artist in artists) ServerFeedItem(artist)],
      albums: [for (final album in albums) ServerFeedItem(album)],
      songs: songs,
    );
  }

  /// The server and everything outside it.
  Future<MusicSearchOutcome> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const MusicSearchOutcome();
    final q = Deezer.normal(query);

    final variants = _variants(q, query);
    final results = await Future.wait<Object?>([
      quietly(_itunesSongs(query), null, 'iTunes song search'),
      quietly(_itunesAlbums(query), null, 'iTunes album search'),
      quietly(_deezerTracks(query), const <_Scored<ChartTrack>>[], 'song search'),
      quietly(discovery.catalog.search(query), null, 'library search'),
      for (final variant in variants)
        quietly(_deezerArtists(variant), const <_Scored<DiscoverArtist>>[], 'artist search'),
    ]);
    final itunesSongs = results[0] as List<ChartTrack>?;
    final itunesAlbums = results[1] as List<DiscoverAlbum>?;
    final deezerTracks = results[2] as List<_Scored<ChartTrack>>;
    final library = results[3] as MusicSearchResults?;
    final artistLists = [for (final result in results.skip(4)) result as List<_Scored<DiscoverArtist>>];

    // ---- Artists: one per name, the most popular one with that name (AJR, not "A.J.R.").
    final byName = <String, _Scored<DiscoverArtist>>{};
    for (final list in artistLists) {
      for (final candidate in list) {
        final name = Deezer.normal(candidate.value.name);
        final existing = byName[name];
        if (existing == null || candidate.popularity > existing.popularity) byName[name] = candidate;
      }
    }
    // Artists the top songs are by count as a vote for them (Apple's view of who's meant).
    final songArtists = <String>[
      for (final song in itunesSongs ?? const <ChartTrack>[]) Deezer.normal(song.artistName),
    ];
    final rankedArtists = byName.entries.map((entry) {
      final first = songArtists.indexWhere((artist) => artist == entry.key || artist.startsWith(entry.key));
      final presence = first < 0 ? 0.0 : 0.15 * (1 - first / max(songArtists.length, 1));
      return _Scored(entry.value.value, _text(q, entry.key) * 0.5 + entry.value.popularity * 0.35 + presence, entry.value.popularity);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final topArtist = rankedArtists.isEmpty ? null : rankedArtists.first;
    final artistIsMeant = topArtist != null &&
        _text(q, Deezer.normal(topArtist.value.name)) >= 0.75 &&
        topArtist.popularity >= 0.45 &&
        topArtist.score >= 0.75;

    // When the query is an artist, fill the results with their music too.
    List<ChartTrack> artistSongs = const [];
    List<DiscoverAlbum> artistAlbums = const [];
    final meant = artistIsMeant ? topArtist?.value : null;
    if (meant != null) {
      final more = await Future.wait<Object?>([
        quietly(_itunesSongs(meant.name), null, 'iTunes artist songs'),
        quietly(Deezer.albumsBy(meant), const <DiscoverAlbum>[], 'artist albums'),
      ]);
      artistSongs = [
        for (final song in (more[0] as List<ChartTrack>?) ?? const <ChartTrack>[])
          if (Deezer.normal(song.artistName).contains(Deezer.normal(meant.name))) song,
      ];
      artistAlbums = more[1] as List<DiscoverAlbum>;
    }

    // ---- Songs: Apple's order first, then Deezer's for anything Apple didn't have.
    final songs = <SearchSong>[];
    final seen = <String>{};
    void addSong(ChartTrack track, double score) {
      final song = SearchSong.external(track, score);
      if (seen.add(song.key)) songs.add(song);
    }

    final apple = itunesSongs ?? const <ChartTrack>[];
    for (final (index, track) in apple.indexed) {
      addSong(track, 1.0 - index / max(apple.length, 1) * 0.5);
    }
    for (final (index, track) in artistSongs.indexed) {
      addSong(track, 0.6 - index * 0.01);
    }
    for (final candidate in deezerTracks) {
      final relevance = max(_text(q, Deezer.normal(candidate.value.title)), _text(q, Deezer.normal(candidate.value.artistName)) * 0.9);
      addSong(candidate.value, (apple.isEmpty ? 0.6 : 0.35) * relevance + candidate.popularity * 0.3);
    }
    // Ours: take the place of the outside copy, or join on relevance.
    for (final track in library?.songs ?? const <MediaItem>[]) {
      final ours = SearchSong.server(track, 0);
      final existing = songs.indexWhere((song) => song.key == ours.key);
      if (existing >= 0) {
        songs[existing] = SearchSong.server(track, songs[existing].score + 0.02);
      } else if (seen.add(ours.key)) {
        final relevance = max(_text(q, Deezer.normal(track.title ?? '')), _text(q, Deezer.normal(track.trackArtistTitle ?? '')) * 0.9);
        songs.add(SearchSong.server(track, 0.5 * relevance + 0.2));
      }
    }
    songs.sort((a, b) => b.score.compareTo(a.score));

    // ---- Albums: Apple's order, then the artist's own releases.
    final albumList = <DiscoverAlbum>[
      ...?itunesAlbums,
      ...artistAlbums,
      if (itunesAlbums == null)
        for (final song in apple.take(10)) song.album,
    ];
    final albums = await discovery.resolve(albumList, limit: 30);
    final serverAlbums = [
      for (final album in library?.albums ?? const <MediaItem>[])
        if (!albums.any((card) => card is ServerFeedItem && card.item.id == album.id)) ServerFeedItem(album),
    ];

    final artists = await discovery.resolveArtists([for (final candidate in rankedArtists.take(14)) candidate.value]);
    final serverArtists = [
      for (final artist in library?.artists ?? const <MediaItem>[])
        if (!artists.any((card) => card is ServerFeedItem && card.item.id == artist.id) &&
            _text(q, Deezer.normal(artist.title ?? '')) >= 0.6)
          ServerFeedItem(artist),
    ];

    return MusicSearchOutcome(
      top: artistIsMeant && artists.isNotEmpty ? artists.first : null,
      topSong: !artistIsMeant && songs.isNotEmpty ? songs.first : null,
      artists: [...artists, ...serverArtists],
      albums: [...albums, ...serverAlbums],
      songs: songs.take(40).toList(),
    );
  }

  /// The query and, for short ones, spellings one letter off: "siza" also tries "sza".
  static List<String> _variants(String normalized, String raw) {
    final variants = <String>[raw];
    if (normalized.length >= 3 && normalized.length <= 8) {
      const vowels = 'aeiouy';
      for (var i = 1; i < normalized.length && variants.length < 3; i++) {
        if (!vowels.contains(normalized[i])) continue;
        final dropped = normalized.substring(0, i) + normalized.substring(i + 1);
        if (dropped.length >= 2 && !variants.contains(dropped)) variants.add(dropped);
      }
    }
    return variants;
  }

  /// How well [name] matches [query] (both normalized), 0..1.
  static double _text(String query, String name) {
    if (query.isEmpty || name.isEmpty) return 0;
    if (name == query) return 1;
    if (name.startsWith(query)) return 0.9 - min(0.2, (name.length - query.length) * 0.01);
    if (name.contains(query)) return 0.75;
    final distance = _levenshtein(query, name);
    final similarity = 1 - distance / max(query.length, name.length);
    final prefix = name.length > query.length
        ? 1 - _levenshtein(query, name.substring(0, query.length)) / query.length
        : 0.0;
    return max(similarity, prefix * 0.7).clamp(0.0, 1.0);
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = min(min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost);
      }
      previous = current;
    }
    return previous[b.length];
  }

  // ---- Sources.

  static Future<Object?> _json(Uri uri) => _cache.putIfAbsent(uri.toString(), () async {
    try {
      final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) throw http.ClientException('${response.statusCode}', uri);
      return jsonDecode(response.body);
    } catch (_) {
      _cache.remove(uri.toString());
      rethrow;
    }
  });

  static List<Map> _data(Object? json, [String key = 'data']) {
    final data = json is Map ? json[key] : null;
    return data is List ? data.whereType<Map>().toList() : const [];
  }

  static double _popularity(num? count, {double ceiling = 8}) =>
      count == null || count <= 0 ? 0.0 : (log(count + 1) / ln10 / ceiling).clamp(0.0, 1.0);

  static String? _art(Object? url) => url is String ? url.replaceFirst('100x100bb', '600x600bb') : null;

  /// "Title - Single" / "Title - EP" → ("Title", "Single").
  static (String, String?) _splitType(String title, Object? trackCount) {
    for (final type in const ['Single', 'EP']) {
      if (title.endsWith(' - $type')) return (title.substring(0, title.length - type.length - 3), type);
    }
    return (title, trackCount == 1 ? 'Single' : null);
  }

  static DiscoverAlbum? _itunesAlbum(Map entry) {
    final id = entry['collectionId'];
    final name = entry['collectionName'];
    if (id is! num || name is! String) return null;
    final (title, type) = _splitType(name, entry['trackCount']);
    final date = entry['releaseDate'];
    return DiscoverAlbum(
      mbid: 'it:${id.toInt()}',
      title: title,
      artistName: entry['artistName'] as String? ?? '',
      coverUrl: _art(entry['artworkUrl100']),
      releaseDate: date is String && date.length >= 10 ? date.substring(0, 10) : null,
      type: type ?? 'Album',
    );
  }

  static Future<List<ChartTrack>> _itunesSongs(String query) async {
    final json = await _json(
      Uri.https('itunes.apple.com', '/search', {'term': query, 'entity': 'song', 'limit': '30'}),
    );
    final songs = <ChartTrack>[];
    for (final entry in _data(json, 'results')) {
      final album = _itunesAlbum(entry);
      final id = entry['trackId'];
      final title = entry['trackName'];
      if (album == null || id is! num || title is! String) continue;
      songs.add(
        ChartTrack(
          id: id.toInt(),
          rank: songs.length + 1,
          title: title,
          artistName: entry['artistName'] as String? ?? album.artistName,
          album: album,
          previewUrl: entry['previewUrl'] as String?,
          length: entry['trackTimeMillis'] is num ? Duration(milliseconds: (entry['trackTimeMillis'] as num).toInt()) : null,
        ),
      );
    }
    return songs;
  }

  static Future<List<DiscoverAlbum>> _itunesAlbums(String query) async {
    final json = await _json(
      Uri.https('itunes.apple.com', '/search', {'term': query, 'entity': 'album', 'limit': '20'}),
    );
    return [
      for (final entry in _data(json, 'results')) ?_itunesAlbum(entry),
    ];
  }

  static Future<List<_Scored<DiscoverArtist>>> _deezerArtists(String query) async {
    final json = await _json(Uri.https('api.deezer.com', '/search/artist', {'q': query, 'limit': '15'}));
    return [
      for (final entry in _data(json))
        if (Deezer.artistFrom(entry) case final artist?) _Scored(artist, 0, _popularity(entry['nb_fan'] as num?)),
    ];
  }

  static Future<List<_Scored<ChartTrack>>> _deezerTracks(String query) async {
    final json = await _json(Uri.https('api.deezer.com', '/search/track', {'q': query, 'limit': '30'}));
    final tracks = <_Scored<ChartTrack>>[];
    for (final entry in _data(json)) {
      final album = Deezer.albumFrom(entry['album'], artist: entry['artist']);
      final id = entry['id'];
      if (album == null || id is! num) continue;
      final preview = entry['preview'];
      tracks.add(
        _Scored(
          ChartTrack(
            id: id.toInt(),
            rank: tracks.length + 1,
            title: (entry['title_short'] ?? entry['title'] ?? '') as String,
            artistName: album.artistName,
            album: album,
            previewUrl: preview is String && preview.isNotEmpty ? preview : null,
            length: entry['duration'] is num ? Duration(seconds: (entry['duration'] as num).toInt()) : null,
          ),
          0,
          _popularity(entry['rank'] as num?, ceiling: 6),
        ),
      );
    }
    return tracks;
  }
}

class _Scored<T> {
  const _Scored(this.value, this.score, this.popularity);

  final T value;
  final double score;
  final double popularity;
}
