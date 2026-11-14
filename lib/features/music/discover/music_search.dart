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
}

class MusicSearchOutcome {
  const MusicSearchOutcome({this.top, this.artists = const [], this.albums = const [], this.songs = const []});

  final MusicFeedItem? top;
  final List<MusicFeedItem> artists;
  final List<MusicFeedItem> albums;
  final List<SearchSong> songs;

  bool get isEmpty => top == null && artists.isEmpty && albums.isEmpty && songs.isEmpty;
}

/// Atlas: music search across the server and the world, typo-tolerant, with popular things
/// first. Typing "siza" finds SZA (not an unknown artist literally called Siza), and "AJR" puts
/// the band behind "Bang!" on top with their music filling the results.
///
/// How: Deezer's catalog (with fan counts and play ranks) is searched for the query plus a few
/// one-letter-off spellings, the iTunes Store's search adds its own ordering as a second opinion,
/// and every candidate is scored on how close its name is AND how popular it is. The server's own
/// library is searched too, and anything we already have shows as ours.
class MusicSearch {
  MusicSearch(this.discovery);

  final MusicDiscovery discovery;

  static const _headers = {'User-Agent': 'Atlas/1.0', 'Accept': 'application/json'};

  Future<MusicSearchOutcome> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const MusicSearchOutcome();
    final q = Deezer.normal(query);

    // Artists first: they decide what the rest of the results are about.
    final variants = _variants(q, query);
    final artistLists = await Future.wait([
      for (final variant in variants) quietly(_deezerArtists(variant), const <_Scored<DiscoverArtist>>[], 'artist search'),
    ]);
    final itunesOrder = await quietly(_itunesArtists(query), const <String>[], 'iTunes artist search');
    final artistsByName = <String, _Scored<DiscoverArtist>>{};
    for (final list in artistLists) {
      for (final candidate in list) {
        artistsByName.putIfAbsent(Deezer.normal(candidate.value.name), () => candidate);
      }
    }
    final rankedArtists = artistsByName.values.map((candidate) {
      final name = Deezer.normal(candidate.value.name);
      final itunesRank = itunesOrder.indexOf(name);
      final itunesBonus = itunesRank < 0 ? 0.0 : 0.12 * (1 - itunesRank / max(itunesOrder.length, 1));
      return _Scored(candidate.value, _text(q, name) * 0.55 + candidate.popularity * 0.35 + itunesBonus, candidate.popularity);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final topArtist = rankedArtists.isNotEmpty && rankedArtists.first.score > 0.55 ? rankedArtists.first.value : null;
    final aboutArtist = topArtist != null && Deezer.normal(topArtist.name) != q ? topArtist.name : null;

    // Albums and songs: for the query, and for the artist it's clearly about.
    final results = await Future.wait<Object?>([
      quietly(_deezerAlbums(query), const <_Scored<DiscoverAlbum>>[], 'album search'),
      quietly(_deezerTracks(query), const <_Scored<ChartTrack>>[], 'song search'),
      if (aboutArtist != null) ...[
        quietly(_deezerAlbums('artist:"$aboutArtist"'), const <_Scored<DiscoverAlbum>>[], 'album search'),
        quietly(_deezerTracks('artist:"$aboutArtist"'), const <_Scored<ChartTrack>>[], 'song search'),
      ],
      quietly(discovery.catalog.search(query), null, 'library search'),
      if (aboutArtist != null) quietly(discovery.catalog.search(aboutArtist), null, 'library search'),
    ]);

    final albumCandidates = <_Scored<DiscoverAlbum>>[
      ...results[0] as List<_Scored<DiscoverAlbum>>,
      if (aboutArtist != null) ...results[2] as List<_Scored<DiscoverAlbum>>,
    ];
    final trackCandidates = <_Scored<ChartTrack>>[
      ...results[1] as List<_Scored<ChartTrack>>,
      if (aboutArtist != null) ...results[3] as List<_Scored<ChartTrack>>,
    ];
    final libraryResults = [
      for (final result in results.skip(aboutArtist != null ? 4 : 2))
        if (result case final MusicSearchResults found) found,
    ];

    final topName = topArtist == null ? null : Deezer.normal(topArtist.name);
    double relevance(String title, String artist) {
      final t = _text(q, Deezer.normal(title));
      final a = Deezer.normal(artist);
      final byArtist = topName != null && a == topName ? 0.85 : _text(q, a) * 0.9;
      return max(t, byArtist);
    }

    // Albums.
    final seenAlbums = <String>{};
    final rankedAlbums = <_Scored<DiscoverAlbum>>[
      for (final candidate in albumCandidates)
        if (seenAlbums.add(MusicDiscovery.albumKey(candidate.value.artistName, candidate.value.title)))
          _Scored(
            candidate.value,
            relevance(candidate.value.title, candidate.value.artistName) * 0.6 + candidate.popularity * 0.4,
            candidate.popularity,
          ),
    ]..sort((a, b) => b.score.compareTo(a.score));

    // Songs from outside, then ours mixed in by the same scoring.
    final seenSongs = <String>{};
    final songs = <SearchSong>[
      for (final candidate in trackCandidates)
        if (seenSongs.add('${Deezer.normal(candidate.value.artistName)}|${Deezer.normal(candidate.value.title)}'))
          SearchSong.external(
            candidate.value,
            relevance(candidate.value.title, candidate.value.artistName) * 0.6 + candidate.popularity * 0.4,
          ),
    ];
    final serverArtists = <MediaItem>[];
    final serverAlbums = <MediaItem>[];
    for (final found in libraryResults) {
      serverArtists.addAll(found.artists);
      serverAlbums.addAll(found.albums);
      for (final track in found.songs) {
        final key = '${Deezer.normal(track.trackArtistTitle ?? track.albumArtistTitle ?? '')}|${Deezer.normal(track.title ?? '')}';
        final existing = songs.indexWhere(
          (song) => song.external != null &&
              '${Deezer.normal(song.external!.artistName)}|${Deezer.normal(song.external!.title)}' == key,
        );
        if (existing >= 0) {
          // We have it: keep its place, make it ours (and nudge it up).
          songs[existing] = SearchSong.server(track, songs[existing].score + 0.05);
        } else if (seenSongs.add(key)) {
          songs.add(SearchSong.server(track, relevance(track.title ?? '', track.trackArtistTitle ?? '') * 0.6 + 0.25));
        }
      }
    }
    songs.sort((a, b) => b.score.compareTo(a.score));

    // Cards: the server's copies where we have them.
    final artistCards = await discovery.resolveArtists([for (final a in rankedArtists.take(12)) a.value], limit: 12);
    final albumCards = await discovery.resolve([for (final a in rankedAlbums.take(30)) a.value], limit: 24);
    final artistKeys = {for (final card in artistCards) _cardName(card)};
    final albumKeys = {for (final card in albumCards) _cardName(card)};
    final extraArtists = [
      for (final artist in serverArtists)
        if (artistKeys.add(Deezer.normal(artist.title ?? '')) && _text(q, Deezer.normal(artist.title ?? '')) > 0.6)
          ServerFeedItem(artist),
    ];
    final extraAlbums = [
      for (final album in serverAlbums)
        if (albumKeys.add(Deezer.normal(album.title ?? ''))) ServerFeedItem(album),
    ];

    final artists = [...artistCards, ...extraArtists];
    final albums = [...albumCards, ...extraAlbums];
    final top = _pickTop(rankedArtists, rankedAlbums, artists, albums);
    return MusicSearchOutcome(top: top, artists: artists, albums: albums, songs: songs.take(30).toList());
  }

  /// The best artist when the query is clearly them; otherwise the best album.
  static MusicFeedItem? _pickTop(
    List<_Scored<DiscoverArtist>> rankedArtists,
    List<_Scored<DiscoverAlbum>> rankedAlbums,
    List<MusicFeedItem> artists,
    List<MusicFeedItem> albums,
  ) {
    final artistScore = rankedArtists.isEmpty ? 0.0 : rankedArtists.first.score;
    final albumScore = rankedAlbums.isEmpty ? 0.0 : rankedAlbums.first.score;
    if (artists.isNotEmpty && artistScore >= albumScore - 0.05) return artists.first;
    if (albums.isNotEmpty) return albums.first;
    return artists.isNotEmpty ? artists.first : null;
  }

  static String _cardName(MusicFeedItem card) => switch (card) {
    ServerFeedItem(:final item) => Deezer.normal(item.title ?? ''),
    ExternalAlbumItem(:final album) => Deezer.normal(album.title),
    ExternalArtistItem(:final artist) => Deezer.normal(artist.name),
  };

  /// The query and, for short ones, spellings one letter off (dropping a letter, mostly vowels):
  /// "siza" also tries "sza" and "siz".
  static List<String> _variants(String normalized, String raw) {
    final variants = <String>[raw];
    if (normalized.length >= 3 && normalized.length <= 8) {
      const vowels = 'aeiouy';
      for (var i = 1; i < normalized.length && variants.length < 4; i++) {
        if (!vowels.contains(normalized[i])) continue;
        final dropped = normalized.substring(0, i) + normalized.substring(i + 1);
        if (dropped.length >= 2 && !variants.contains(dropped)) variants.add(dropped);
      }
      if (variants.length < 3) {
        final shorter = normalized.substring(0, normalized.length - 1);
        if (shorter.length >= 2 && !variants.contains(shorter)) variants.add(shorter);
      }
    }
    return variants;
  }

  /// How well [name] matches [query] (both normalized), 0..1.
  static double _text(String query, String name) {
    if (query.isEmpty || name.isEmpty) return 0;
    if (name == query) return 1;
    if (name.startsWith(query)) return 0.9 - min(0.2, (name.length - query.length) * 0.01);
    if (name.contains(query)) return 0.78;
    final distance = _levenshtein(query, name);
    final similarity = 1 - distance / max(query.length, name.length);
    // Close to the start of a longer name ("bang" in "bangbang") counts a bit too.
    final prefix = name.length > query.length ? 1 - _levenshtein(query, name.substring(0, query.length)) / query.length : 0.0;
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

  static Future<Object?> _json(Uri uri) async {
    final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    return jsonDecode(response.body);
  }

  static List<Map> _data(Object? json, [String key = 'data']) {
    final data = json is Map ? json[key] : null;
    return data is List ? data.whereType<Map>().toList() : const [];
  }

  /// Popularity 0..1 from a count that spans orders of magnitude (fans, plays).
  static double _popularity(num? count, {double ceiling = 8}) =>
      count == null || count <= 0 ? 0.0 : (log(count + 1) / ln10 / ceiling).clamp(0.0, 1.0);

  static Future<List<_Scored<DiscoverArtist>>> _deezerArtists(String query) async {
    final json = await _json(Uri.https('api.deezer.com', '/search/artist', {'q': query, 'limit': '15'}));
    return [
      for (final entry in _data(json))
        if (Deezer.artistFrom(entry) case final artist?)
          _Scored(artist, 0, _popularity(entry['nb_fan'] as num?)),
    ];
  }

  static Future<List<_Scored<DiscoverAlbum>>> _deezerAlbums(String query) async {
    final json = await _json(Uri.https('api.deezer.com', '/search/album', {'q': query, 'limit': '25'}));
    final list = _data(json);
    return [
      for (final (index, entry) in list.indexed)
        if (Deezer.albumFrom(entry) case final album?)
          // Deezer puts the most listened first; the position is the popularity signal here.
          _Scored(album, 0, (1 - index / max(list.length, 1)) * 0.8),
    ];
  }

  static Future<List<_Scored<ChartTrack>>> _deezerTracks(String query) async {
    final json = await _json(Uri.https('api.deezer.com', '/search/track', {'q': query, 'limit': '30'}));
    final tracks = <_Scored<ChartTrack>>[];
    for (final entry in _data(json)) {
      final album = Deezer.albumFrom(entry['album'], artist: entry['artist']);
      final id = entry['id'];
      if (album == null || id is! num) continue;
      tracks.add(
        _Scored(
          ChartTrack(
            id: id.toInt(),
            rank: tracks.length + 1,
            title: (entry['title_short'] ?? entry['title'] ?? '') as String,
            artistName: album.artistName,
            album: album,
            previewUrl: entry['preview'] is String && (entry['preview'] as String).isNotEmpty ? entry['preview'] as String : null,
            length: entry['duration'] is num ? Duration(seconds: (entry['duration'] as num).toInt()) : null,
          ),
          0,
          // Deezer's track rank runs up to about a million.
          _popularity(entry['rank'] as num?, ceiling: 6),
        ),
      );
    }
    return tracks;
  }

  /// The iTunes Store's artist order for the query (normalized names), a second opinion on
  /// what people mean.
  static Future<List<String>> _itunesArtists(String query) async {
    final json = await _json(
      Uri.https('itunes.apple.com', '/search', {'term': query, 'entity': 'musicArtist', 'limit': '8'}),
    );
    return [
      for (final entry in _data(json, 'results'))
        if (entry['artistName'] case final String name) Deezer.normal(name),
    ];
  }
}

class _Scored<T> {
  const _Scored(this.value, this.score, this.popularity);

  final T value;
  final double score;
  final double popularity;
}
