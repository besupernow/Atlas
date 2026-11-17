import 'dart:math';

import '../../../media/media_item.dart';
import '../data/music_catalog.dart';
import 'allseerr_music.dart';
import 'deezer.dart';
import 'discover_feed.dart';
import 'discover_models.dart';
import 'lastfm.dart';
import 'music_search_index.dart';
import 'musicbrainz.dart';
import 'tidal.dart';
import '../../../services/music/music_bans.dart';

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

  String get key => SearchText.songKey(artist, title);

  /// Everyone on the song, for clickable names.
  ArtistCredit get credit {
    final track = external;
    if (track != null) return ArtistCredit([track.artistName], track.featuring);
    return ArtistCredit.parse(artist);
  }
}

class MusicSearchOutcome {
  /// Atlas: [raw] without anything this person hid.
  factory MusicSearchOutcome.visible(MusicSearchOutcome raw) {
    bool songHidden(SearchSong song) {
      final server = song.server;
      if (server != null) return MusicBans.instance.blocks(server);
      return song.external?.isHidden ?? false;
    }

    final top = raw.top;
    final topSong = raw.topSong;
    return MusicSearchOutcome(
      top: top == null || top.isHidden ? null : top,
      topSong: topSong == null || songHidden(topSong) ? null : topSong,
      artists: [for (final item in raw.artists) if (!item.isHidden) item],
      albums: [for (final item in raw.albums) if (!item.isHidden) item],
      songs: [for (final song in raw.songs) if (!songHidden(song)) song],
    );
  }

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

/// Atlas: music search across the server and the world.
///
/// Three sources, each good at something: Deezer (artwork, previews, play counts as "rank",
/// fan counts), Last.fm (how many people listen, what's charting right now) and MusicBrainz (the
/// ids and codes everything else is tied together with, and what Allseerr requests are made
/// with). Their results are linked into one set of songs, albums and artists, by ISRC and
/// MusicBrainz id where the sources share them and by artist, title and length where they
/// don't, then ranked on the device ([MusicSearchIndex]): typo-tolerant text matching, with
/// popularity and trending deciding between close matches. So "siza" finds SZA, and "AJR" finds
/// the band, with their songs filling the results.
///
/// Every album that comes out of here carries its codes ([MusicIds]), which is how a request
/// later finds exactly the right MusicBrainz release group.
class MusicSearch {
  MusicSearch(this.discovery);

  final MusicDiscovery discovery;

  // Shared for the session: later searches get instant results from earlier ones.
  static final _songs = MusicSearchIndex<ChartTrack>();
  static final _albums = MusicSearchIndex<DiscoverAlbum>();
  static final _artists = MusicSearchIndex<DiscoverArtist>();

  /// Results from what earlier searches already brought in, without the network. Shown while
  /// [search] is still out asking.
  MusicSearchOutcome instant(String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty || _songs.length + _artists.length == 0) return const MusicSearchOutcome();
    // Songs from outside only show when they can be previewed.
    final songs = _songs.search(query, minRelevance: 0.6, limit: 30).where((hit) => hit.value.previewUrl != null).toList();
    final artists = _artists.search(query, minRelevance: 0.6, limit: 10);
    final albums = _albums.search(query, minRelevance: 0.6, limit: 15);
    final meant = _artistIsMeant(artists, songs);
    return MusicSearchOutcome(
      top: meant ? ExternalArtistItem(artists.first.value) : null,
      topSong: !meant && songs.isNotEmpty ? SearchSong.external(songs.first.value, songs.first.score) : null,
      artists: [for (final hit in artists) ExternalArtistItem(hit.value)],
      albums: [for (final hit in albums) ExternalAlbumItem(hit.value)],
      songs: [for (final hit in songs) SearchSong.external(hit.value, hit.score)],
    );
  }

  /// Only what's on the server (the Library tab).
  Future<MusicSearchOutcome> searchLibrary(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const MusicSearchOutcome();
    final found = await discovery.catalog.search(query);
    double score(List<(String, double)> fields) => MusicSearchIndex.relevance(query, fields);
    double artistScore(MediaItem artist) => score([(artist.title ?? '', 1)]);
    double albumScore(MediaItem album) => score([(album.title ?? '', 1), (album.albumArtistTitle ?? '', 0.9)]);
    final artists = [...found.artists]..sort((a, b) => artistScore(b).compareTo(artistScore(a)));
    final albums = [...found.albums]..sort((a, b) => albumScore(b).compareTo(albumScore(a)));
    final songs = [
      for (final track in found.songs)
        SearchSong.server(
          track,
          score([(track.title ?? '', 1), (track.trackArtistTitle ?? '', 0.9), (track.albumTitle ?? '', 0.6)]),
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final topArtist = artists.isNotEmpty && artistScore(artists.first) >= 0.9 ? artists.first : null;
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

    final variants = _variants(SearchText.squash(query), query);
    final results = await Future.wait<Object?>([
      quietly(_deezerTracks(query), const <_DeezerTrack>[], 'Deezer song search'),
      quietly(_deezerAlbums(query), const <DiscoverAlbum>[], 'Deezer album search'),
      quietly(LastFm.searchTracks(query), const <LastFmHit>[], 'Last.fm song search'),
      quietly(LastFm.searchArtists(query), const <LastFmHit>[], 'Last.fm artist search'),
      quietly(LastFm.searchAlbums(query), const <LastFmHit>[], 'Last.fm album search'),
      quietly(MusicBrainz.searchRecordings(query), const <MbRecording>[], 'MusicBrainz search'),
      quietly(_Trending.load(), _Trending.empty, 'charts'),
      quietly(discovery.catalog.search(query), null, 'library search'),
      quietly(Tidal.search(query), TidalSearchResults.empty, 'TIDAL search'),
      for (final variant in variants)
        quietly(_deezerArtists(variant), const <_DeezerArtist>[], 'Deezer artist search'),
    ]);
    final deezerTracks = results[0] as List<_DeezerTrack>;
    final deezerAlbums = results[1] as List<DiscoverAlbum>;
    final lastFmTracks = results[2] as List<LastFmHit>;
    final lastFmArtists = results[3] as List<LastFmHit>;
    final lastFmAlbums = results[4] as List<LastFmHit>;
    final recordings = results[5] as List<MbRecording>;
    final trending = results[6] as _Trending;
    final library = results[7] as MusicSearchResults?;
    final tidal = results[8] as TidalSearchResults;
    final deezerArtists = [for (final result in results.skip(9)) ...result as List<_DeezerArtist>];

    // ---- Link everything into one set of songs, albums and artists, then index it.
    final linker = _Linker(trending)
      ..addDeezerTracks(deezerTracks)
      ..addTidal(tidal)
      ..addRecordings(recordings)
      ..addLastFmTracks(lastFmTracks)
      ..addDeezerAlbums(deezerAlbums)
      ..addLastFmAlbums(lastFmAlbums)
      ..addDeezerArtists(deezerArtists)
      ..addLastFmArtists(lastFmArtists)
      ..addRecordingArtists(recordings);
    // TIDAL's songs have no previews: Deezer has the same recording by ISRC.
    await linker.addPreviews();
    linker.indexInto(songs: _songs, albums: _albums, artists: _artists);

    final artistHits = _artists.search(query, limit: 14);
    final songHits = _songs.search(query, limit: 50);
    final meant = _artistIsMeant(artistHits, songHits);
    final meantArtist = meant ? artistHits.first.value : null;

    // When the query is an artist, fill the results with their music too.
    if (meantArtist != null) {
      final more = await Future.wait<Object?>([
        quietly(_deezerTracks('artist:"${meantArtist.name}"'), const <_DeezerTrack>[], 'artist songs'),
        quietly(Deezer.albumsBy(meantArtist), const <DiscoverAlbum>[], 'artist albums'),
      ]);
      final want = SearchText.squash(meantArtist.name);
      final artistLinker = _Linker(trending)
        ..addDeezerTracks([
          for (final track in more[0] as List<_DeezerTrack>)
            if (SearchText.squash(track.track.artistName).contains(want)) track,
        ])
        ..addDeezerAlbums(more[1] as List<DiscoverAlbum>);
      artistLinker.indexInto(songs: _songs, albums: _albums, artists: _artists, artistBoost: meantArtist.name);
    }

    // ---- Songs, in the index's order; when an artist is meant, theirs first.
    final songsRanked = [
      ..._songs.search(query, limit: 50),
      if (meantArtist != null) ..._songs.search(meantArtist.name, minRelevance: 0.55, limit: 30),
    ];
    final songs = <SearchSong>[];
    final seen = <String>{};
    for (final hit in songsRanked) {
      // Songs from outside only show when they can be previewed.
      if (hit.value.previewUrl == null) continue;
      final song = SearchSong.external(hit.value, hit.score);
      if (seen.add(song.key)) songs.add(song);
    }
    // Ours: take the place of the outside copy, or join on relevance.
    for (final track in library?.songs ?? const <MediaItem>[]) {
      final ours = SearchSong.server(track, 0);
      final existing = songs.indexWhere((song) => song.key == ours.key);
      if (existing >= 0) {
        songs[existing] = SearchSong.server(track, songs[existing].score);
      } else if (seen.add(ours.key)) {
        final relevance = MusicSearchIndex.relevance(query, [
          (track.title ?? '', 1),
          (track.trackArtistTitle ?? '', 0.9),
        ]);
        if (relevance >= 0.5) songs.add(SearchSong.server(track, MusicSearchIndex.combine(relevance, 0.4, 0)));
      }
    }
    songs.sort((a, b) => b.score.compareTo(a.score));
    if (meantArtist != null) {
      // Theirs first ("AJR": mostly AJR, then anything else close), each group by score.
      final want = SearchText.squash(meantArtist.name);
      songs.sort((a, b) {
        final ta = SearchText.squash(a.artist).contains(want) ? 0 : 1;
        final tb = SearchText.squash(b.artist).contains(want) ? 0 : 1;
        return ta != tb ? ta.compareTo(tb) : b.score.compareTo(a.score);
      });
    }

    // ---- Albums: the index's order, the meant artist's own after.
    final albumHits = [
      ..._albums.search(query, limit: 30),
      if (meantArtist != null) ..._albums.search(meantArtist.name, minRelevance: 0.55, limit: 30),
    ];
    final albumList = <DiscoverAlbum>[];
    final albumKeys = <String>{};
    for (final hit in albumHits) {
      if (albumKeys.add(SearchText.albumKey(hit.value.artistName, hit.value.title))) albumList.add(hit.value);
    }
    final albums = await discovery.resolve(albumList, limit: 30);
    final serverAlbums = [
      for (final album in library?.albums ?? const <MediaItem>[])
        if (!albums.any((card) => card is ServerFeedItem && card.item.id == album.id)) ServerFeedItem(album),
    ];

    final artists = await discovery.resolveArtists([for (final hit in artistHits) hit.value]);
    final serverArtists = [
      for (final artist in library?.artists ?? const <MediaItem>[])
        if (!artists.any((card) => card is ServerFeedItem && card.item.id == artist.id) &&
            MusicSearchIndex.relevance(query, [(artist.title ?? '', 1)]) >= 0.6)
          ServerFeedItem(artist),
    ];

    return MusicSearchOutcome(
      top: meant && artists.isNotEmpty ? artists.first : null,
      topSong: !meant && songs.isNotEmpty ? songs.first : null,
      artists: [...artists, ...serverArtists],
      albums: [...albums, ...serverAlbums],
      songs: songs.take(40).toList(),
    );
  }

  /// Whether the query names an artist (Apple Music puts the artist on top then): the name
  /// fits closely, lots of people play them, and no song fits the query better.
  static bool _artistIsMeant(List<SearchHit<DiscoverArtist>> artists, List<SearchHit<ChartTrack>> songs) {
    if (artists.isEmpty) return false;
    final artist = artists.first;
    if (artist.relevance < 0.78 || artist.popularity < 0.4) return false;
    final song = songs.isEmpty ? null : songs.first;
    return song == null || artist.relevance >= song.relevance || artist.score >= song.score;
  }

  /// The query and, for short ones, spellings one letter off: "siza" also asks for "sza".
  static List<String> _variants(String squashed, String raw) {
    final variants = <String>[raw];
    if (squashed.length >= 3 && squashed.length <= 8) {
      const vowels = 'aeiouy';
      for (var i = 1; i < squashed.length && variants.length < 3; i++) {
        if (!vowels.contains(squashed[i])) continue;
        final dropped = squashed.substring(0, i) + squashed.substring(i + 1);
        if (dropped.length >= 2 && !variants.contains(dropped)) variants.add(dropped);
      }
    }
    return variants;
  }

  // ---- Deezer.

  static Future<List<_DeezerArtist>> _deezerArtists(String query) async {
    final json = await Deezer.search('artist', query, limit: 15);
    return [
      for (final entry in json)
        if (Deezer.artistFrom(entry) case final artist?) _DeezerArtist(artist, (entry['nb_fan'] as num?)?.toInt() ?? 0),
    ];
  }

  static Future<List<DiscoverAlbum>> _deezerAlbums(String query) async {
    final json = await Deezer.search('album', query, limit: 25);
    return [for (final entry in json) ?Deezer.albumFrom(entry)];
  }

  static Future<List<_DeezerTrack>> _deezerTracks(String query) async {
    final json = await Deezer.search('track', query, limit: 40);
    final tracks = <_DeezerTrack>[];
    for (final entry in json) {
      final album = Deezer.albumFrom(entry['album'], artist: entry['artist']);
      final id = entry['id'];
      if (album == null || id is! num) continue;
      final preview = entry['preview'];
      final isrc = entry['isrc'];
      tracks.add(
        _DeezerTrack(
          ChartTrack(
            id: id.toInt(),
            rank: tracks.length + 1,
            title: (entry['title_short'] ?? entry['title'] ?? '') as String,
            artistName: album.artistName,
            album: album.copyWith(
              ids: MusicIds(deezerTrackId: id.toInt(), isrc: isrc is String && isrc.isNotEmpty ? isrc : null),
            ),
            previewUrl: preview is String && preview.isNotEmpty ? preview : null,
            length: entry['duration'] is num ? Duration(seconds: (entry['duration'] as num).toInt()) : null,
            featuring: Deezer.featuredIn(entry['title'] as String?),
          ),
          (entry['rank'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return tracks;
  }
}

class _DeezerTrack {
  const _DeezerTrack(this.track, this.rank);

  final ChartTrack track;

  /// Deezer's play-count score, up to about a million.
  final int rank;
}

class _DeezerArtist {
  const _DeezerArtist(this.artist, this.fans);

  final DiscoverArtist artist;
  final int fans;
}

// ---- Popularity, on one 0..1 scale whatever the source.

abstract final class _Popularity {
  static double _log(num value, double floor, double span) =>
      value <= 0 ? 0.0 : ((log(value + 1) / ln10 - floor) / span).clamp(0.0, 1.0);

  /// Deezer's track rank: 10k nothing, 100k middling, 1M a hit.
  static double deezerRank(num rank) => _log(rank, 4, 2);

  /// Last.fm listeners of a song: 1k nobody, 100k known, 3M a hit.
  static double songListeners(num listeners) => _log(listeners, 3, 3.5);

  /// Deezer fans of an artist: 100 nobody, 1M big, 10M+ huge.
  static double fans(num fans) => _log(fans, 2, 5);

  /// Last.fm listeners of an artist.
  static double artistListeners(num listeners) => _log(listeners, 3, 3.8);

  /// Both sources when we have both, otherwise whichever we have.
  static double mix(double? a, double? b, [double? c]) {
    final values = [?a, ?b, ?c];
    return values.isEmpty ? 0 : values.reduce((x, y) => x + y) / values.length;
  }
}

/// What's charting right now on Deezer and Last.fm, refreshed every half hour.
class _Trending {
  const _Trending(this.songs, this.artists);

  /// Song key or artist key → 0..1 (1 is number one).
  final Map<String, double> songs;
  final Map<String, double> artists;

  static const empty = _Trending({}, {});
  static Future<_Trending>? _loaded;
  static DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<_Trending> load() {
    if (_loaded == null || DateTime.now().difference(_at) > const Duration(minutes: 30)) {
      _at = DateTime.now();
      _loaded = _fetch().catchError((Object _) {
        _loaded = null;
        return empty;
      });
    }
    return _loaded!;
  }

  static Future<_Trending> _fetch() async {
    final results = await Future.wait<Object?>([
      quietly(Deezer.topTracks(limit: 100), const <ChartTrack>[], 'Deezer chart'),
      quietly(Deezer.topArtists(limit: 100), const <DiscoverArtist>[], 'Deezer artist chart'),
      quietly(LastFm.chartTracks(), const <LastFmHit>[], 'Last.fm chart'),
      quietly(LastFm.chartArtists(), const <LastFmHit>[], 'Last.fm artist chart'),
    ]);
    final songs = <String, double>{};
    final artists = <String, double>{};
    void note(Map<String, double> into, String key, int index, int count) {
      final value = 1 - index / max(count, 1);
      into[key] = max(into[key] ?? 0, value);
    }

    final deezerSongs = results[0] as List<ChartTrack>;
    for (final (index, track) in deezerSongs.indexed) {
      note(songs, SearchText.songKey(track.artistName, track.title), index, deezerSongs.length);
    }
    final deezerArtists = results[1] as List<DiscoverArtist>;
    for (final (index, artist) in deezerArtists.indexed) {
      note(artists, SearchText.squash(artist.name), index, deezerArtists.length);
    }
    final lastFmSongs = results[2] as List<LastFmHit>;
    for (final (index, hit) in lastFmSongs.indexed) {
      note(songs, SearchText.songKey(hit.artistName, hit.name), index, lastFmSongs.length);
    }
    final lastFmArtists = results[3] as List<LastFmHit>;
    for (final (index, hit) in lastFmArtists.indexed) {
      note(artists, SearchText.squash(hit.name), index, lastFmArtists.length);
    }
    return _Trending(songs, artists);
  }
}

// ---- Linking: the same song, album or artist from different sources becomes one.

class _Song {
  _Song(this.track, {this.deezerRank, this.listeners, this.recordingMbid, this.tidal});

  ChartTrack track;
  int? deezerRank;
  int? listeners;
  String? recordingMbid;

  /// TIDAL's popularity, already 0..1.
  double? tidal;
  final Set<String> isrcs = {};

  double get popularity => _Popularity.mix(
    deezerRank == null ? null : _Popularity.deezerRank(deezerRank!),
    listeners == null ? null : _Popularity.songListeners(listeners!),
    tidal,
  );

  String get key => SearchText.songKey(track.artistName, track.title);
}

class _Artist {
  _Artist(this.artist, {this.fans, this.listeners, this.tidal});

  DiscoverArtist artist;
  int? fans;
  int? listeners;
  double? tidal;

  double get popularity => _Popularity.mix(
    fans == null ? null : _Popularity.fans(fans!),
    listeners == null ? null : _Popularity.artistListeners(listeners!),
    tidal,
  );
}

class _Linker {
  _Linker(this.trending);

  final _Trending trending;

  final List<_Song> _songs = [];
  final Map<String, _Song> _byIsrc = {};
  final Map<String, _Song> _byRecording = {};
  final Map<String, List<_Song>> _byName = {};

  /// Album key → album, the most informative copy kept.
  final Map<String, DiscoverAlbum> _albums = {};

  /// Artist key → artist.
  final Map<String, _Artist> _artists = {};

  /// Album key → the most popular song we saw on it (albums borrow their songs' popularity).
  final Map<String, double> _albumPopularity = {};

  // ---- Songs.

  _Song? _find({Iterable<String> isrcs = const [], String? recording, required String name, Duration? length}) {
    for (final isrc in isrcs) {
      if (_byIsrc[isrc.toUpperCase()] case final song?) return song;
    }
    if (recording != null) {
      if (_byRecording[recording] case final song?) return song;
    }
    for (final song in _byName[name] ?? const <_Song>[]) {
      // Same artist and title, and not a different version (a live take, an extended mix).
      final theirs = song.track.length;
      if (length == null || theirs == null || (theirs - length).abs() <= const Duration(seconds: 15)) return song;
    }
    return null;
  }

  void _remember(_Song song) {
    for (final isrc in song.isrcs) {
      _byIsrc[isrc.toUpperCase()] = song;
    }
    if (song.recordingMbid case final id?) _byRecording[id] = song;
    final list = _byName.putIfAbsent(song.key, () => []);
    if (!list.contains(song)) list.add(song);
  }

  void addDeezerTracks(List<_DeezerTrack> tracks) {
    for (final entry in tracks) {
      final track = entry.track;
      final isrc = track.album.ids.isrc;
      final existing = _find(isrcs: [?isrc], name: SearchText.songKey(track.artistName, track.title), length: track.length);
      if (existing != null) {
        existing.deezerRank = max(existing.deezerRank ?? 0, entry.rank);
        // Deezer's copy has the art and the preview.
        if (existing.track.previewUrl == null) {
          existing.track = _withAlbum(track, existing.track.album.ids);
        }
        if (isrc != null) existing.isrcs.add(isrc);
        _remember(existing);
        continue;
      }
      final song = _Song(track, deezerRank: entry.rank);
      if (isrc != null) song.isrcs.add(isrc);
      _songs.add(song);
      _remember(song);
    }
  }

  // ---- TIDAL: popularity, full credits, ISRCs and barcodes.

  static ChartTrack _copy(ChartTrack track, {int? id, String? previewUrl, DiscoverAlbum? album, List<String>? featuring}) =>
      ChartTrack(
        id: id ?? track.id,
        rank: track.rank,
        title: track.title,
        artistName: track.artistName,
        album: album ?? track.album,
        previewUrl: previewUrl ?? track.previewUrl,
        length: track.length,
        featuring: featuring ?? track.featuring,
      );

  static DiscoverAlbum _tidalAlbum(TidalAlbum album, {String? isrc}) => DiscoverAlbum(
    mbid: 'td:${album.id}',
    title: album.title,
    artistName: album.artists.isEmpty ? '' : album.artists.first,
    featuring: album.artists.skip(1).toList(),
    coverUrl: album.coverUrl,
    releaseDate: album.releaseDate,
    type: album.type,
    ids: MusicIds(upc: album.barcode, isrc: isrc),
  );

  void addTidal(TidalSearchResults results) {
    for (final tidal in results.tracks) {
      final artist = tidal.artists.isNotEmpty ? tidal.artists.first : (tidal.album?.artists.firstOrNull ?? '');
      if (artist.isEmpty) continue;
      final featuring = tidal.artists.skip(1).toList();
      final existing = _find(isrcs: [?tidal.isrc], name: SearchText.songKey(artist, tidal.title), length: tidal.length);
      if (existing != null) {
        existing.tidal = tidal.popularity;
        if (tidal.isrc case final isrc?) existing.isrcs.add(isrc);
        final album = existing.track.album;
        final sameAlbum = tidal.album != null &&
            SearchText.squash(SearchText.cleanTitle(tidal.album!.title)) == SearchText.squash(SearchText.cleanTitle(album.title));
        existing.track = _copy(
          existing.track,
          // The barcode only belongs to this album if it's the same release.
          album: album.copyWith(ids: MusicIds(isrc: tidal.isrc, upc: sameAlbum ? tidal.album!.barcode : null)),
          featuring: existing.track.featuring.isEmpty ? featuring : null,
        );
        _remember(existing);
        continue;
      }
      final tidalAlbum = tidal.album;
      if (tidalAlbum == null) continue;
      final song = _Song(
        ChartTrack(
          id: tidal.id.hashCode,
          rank: _songs.length + 1,
          title: tidal.title,
          artistName: artist,
          album: _tidalAlbum(tidalAlbum, isrc: tidal.isrc),
          length: tidal.length,
          featuring: featuring,
        ),
        tidal: tidal.popularity,
      );
      if (tidal.isrc case final isrc?) song.isrcs.add(isrc);
      _songs.add(song);
      _remember(song);
    }
    for (final album in results.albums) {
      final discover = _tidalAlbum(album);
      _putAlbum(discover);
      final key = SearchText.albumKey(discover.artistName, discover.title);
      _albumPopularity[key] = max(_albumPopularity[key] ?? 0, album.popularity);
    }
    for (final artist in results.artists) {
      final key = SearchText.squash(artist.name);
      final existing = _artists[key];
      if (existing != null) {
        existing.tidal = artist.popularity;
      } else {
        _artists[key] = _Artist(DiscoverArtist(mbid: 'name:${artist.name}', name: artist.name), tidal: artist.popularity);
      }
    }
  }

  /// Songs without a preview (TIDAL's, MusicBrainz's) get Deezer's copy of the same recording
  /// by ISRC: its preview, and its cover when we have none. Without one they don't show.
  Future<void> addPreviews({int limit = 16}) async {
    final missing = [
      for (final song in _songs)
        if (song.track.previewUrl == null && song.isrcs.isNotEmpty) song,
    ].take(limit).toList();
    await Future.wait([
      for (final song in missing)
        () async {
          for (final isrc in song.isrcs.take(2)) {
            final deezer = await quietly(Deezer.trackByIsrc(isrc), null, 'Deezer by ISRC');
            if (deezer == null || deezer.previewUrl == null) continue;
            final album = song.track.album;
            final sameAlbum = SearchText.squash(SearchText.cleanTitle(deezer.album.title)) ==
                SearchText.squash(SearchText.cleanTitle(album.title));
            song.track = _copy(
              song.track,
              id: deezer.id,
              previewUrl: deezer.previewUrl,
              album: album.copyWith(
                coverUrl: album.coverUrl == null ? deezer.album.coverUrl : null,
                deezerId: sameAlbum ? deezer.album.deezerId : null,
              ),
            );
            song.deezerRank ??= deezer.rank > 1000 ? deezer.rank : null;
            return;
          }
        }(),
    ]);
  }

  /// MusicBrainz recordings: they bring the ISRCs and the release group ids. A recording
  /// that matches a Deezer song gives that song's album its release group; one that doesn't
  /// becomes a song of its own (its album from MusicBrainz, art from the Cover Art Archive).
  void addRecordings(List<MbRecording> recordings) {
    for (final recording in recordings) {
      if (recording.score < 60) continue;
      final name = SearchText.songKey(recording.artistName, recording.title);
      final existing = _find(isrcs: recording.isrcs, recording: recording.id, name: name, length: recording.length);
      if (existing != null) {
        existing
          ..recordingMbid ??= recording.id
          ..isrcs.addAll(recording.isrcs);
        final album = existing.track.album;
        final group = _groupFor(recording, album.title);
        existing.track = _withAlbum(
          existing.track,
          MusicIds(
            recordingMbid: recording.id,
            isrc: recording.isrcs.isEmpty ? null : recording.isrcs.first,
            releaseGroupMbid: group?.releaseGroupMbid,
            releaseMbid: (group == null || group.id.isEmpty) ? null : group.id,
          ),
          mbid: group?.releaseGroupMbid,
        );
        _remember(existing);
        continue;
      }
      final release = _groupFor(recording, null);
      if (release == null) continue;
      final album = DiscoverAlbum(
        mbid: release.releaseGroupMbid,
        title: release.releaseGroupTitle,
        artistName: release.artistName ?? recording.artistName,
        artistMbid: recording.artistMbid,
        coverUrl: DiscoverAlbum.coverArtArchiveUrl(release.releaseGroupMbid),
        releaseDate: release.date,
        type: release.primaryType,
        ids: MusicIds(
          releaseGroupMbid: release.releaseGroupMbid,
          releaseMbid: release.id.isEmpty ? null : release.id,
          recordingMbid: recording.id,
          isrc: recording.isrcs.isEmpty ? null : recording.isrcs.first,
        ),
      );
      final song = _Song(
        ChartTrack(
          id: recording.id.hashCode,
          rank: _songs.length + 1,
          title: recording.title,
          artistName: recording.artistName,
          album: album,
          length: recording.length,
        ),
        recordingMbid: recording.id,
      )..isrcs.addAll(recording.isrcs);
      _songs.add(song);
      _remember(song);
    }
  }

  /// The release group of [recording] titled [albumTitle] (when we know which album we mean),
  /// otherwise its earliest original album, EP or single.
  static MbRelease? _groupFor(MbRecording recording, String? albumTitle) {
    if (recording.releases.isEmpty) return null;
    if (albumTitle != null) {
      final want = SearchText.squash(SearchText.cleanTitle(albumTitle));
      for (final release in recording.releases) {
        if (SearchText.squash(SearchText.cleanTitle(release.releaseGroupTitle)) == want) return release;
      }
      return null;
    }
    final originals = [
      for (final release in recording.releases)
        if (release.isOriginal && release.official) release,
    ]..sort((a, b) => (a.date ?? '9999').compareTo(b.date ?? '9999'));
    return originals.isEmpty ? null : originals.first;
  }

  static ChartTrack _withAlbum(ChartTrack track, MusicIds ids, {String? mbid}) => ChartTrack(
    id: track.id,
    rank: track.rank,
    title: track.title,
    artistName: track.artistName,
    album: track.album.copyWith(mbid: MusicIds.isMbid(mbid) ? mbid : null, ids: ids),
    previewUrl: track.previewUrl,
    length: track.length,
    featuring: track.featuring,
  );

  /// Last.fm songs: listener counts for the songs we have (they have no album to show alone).
  void addLastFmTracks(List<LastFmHit> hits) {
    for (final hit in hits) {
      final song = _find(recording: hit.mbid, name: SearchText.songKey(hit.artistName, hit.name));
      if (song == null) continue;
      song.listeners = max(song.listeners ?? 0, hit.listeners);
      song.recordingMbid ??= hit.mbid;
      _remember(song);
    }
  }

  // ---- Albums.

  void _putAlbum(DiscoverAlbum album) {
    final key = SearchText.albumKey(album.artistName, album.title);
    final existing = _albums[key];
    if (existing == null) {
      _albums[key] = album;
      return;
    }
    // Keep Deezer's art and id, MusicBrainz's group id, everyone's codes.
    _albums[key] = existing.copyWith(
      mbid: existing.hasMbid ? null : (album.hasMbid ? album.mbid : null),
      coverUrl: existing.deezerId == null && album.deezerId != null ? album.coverUrl : null,
      deezerId: album.deezerId,
      type: existing.type == null ? album.type : null,
      artistMbid: album.artistMbid,
      ids: album.ids,
    );
  }

  void addDeezerAlbums(List<DiscoverAlbum> albums) {
    for (final album in albums) {
      _putAlbum(album);
    }
  }

  /// Last.fm albums: their ids are MusicBrainz release ids (a request turns one into its group).
  void addLastFmAlbums(List<LastFmHit> hits) {
    for (final hit in hits) {
      final key = SearchText.albumKey(hit.artistName, hit.name);
      final existing = _albums[key];
      if (existing != null) {
        _albums[key] = existing.copyWith(ids: MusicIds(releaseMbid: hit.mbid));
      } else if (hit.mbid != null || hit.imageUrl != null) {
        _albums[key] = DiscoverAlbum(
          mbid: 'lf:$key',
          title: hit.name,
          artistName: hit.artistName,
          coverUrl: hit.imageUrl,
          ids: MusicIds(releaseMbid: hit.mbid),
        );
      }
    }
  }

  // ---- Artists.

  void addDeezerArtists(List<_DeezerArtist> artists) {
    for (final entry in artists) {
      final key = SearchText.squash(entry.artist.name);
      final existing = _artists[key];
      // One per name: the most popular one with it (AJR, not "A.J.R.").
      if (existing == null || (existing.fans ?? -1) < entry.fans) {
        _artists[key] = _Artist(
          existing?.artist.hasMbid ?? false
              ? DiscoverArtist(
                  mbid: existing!.artist.mbid,
                  name: entry.artist.name,
                  imageUrl: entry.artist.imageUrl,
                  backdropUrl: entry.artist.backdropUrl,
                  deezerId: entry.artist.deezerId,
                )
              : entry.artist,
          fans: entry.fans,
          listeners: existing?.listeners,
        );
      }
    }
  }

  void addLastFmArtists(List<LastFmHit> hits) {
    for (final hit in hits) {
      final key = SearchText.squash(hit.name);
      final existing = _artists[key];
      if (existing != null) {
        existing.listeners = max(existing.listeners ?? 0, hit.listeners);
        if (!existing.artist.hasMbid && hit.mbid != null) existing.artist = _withMbid(existing.artist, hit.mbid!);
      } else if (hit.listeners > 0) {
        _artists[key] = _Artist(
          DiscoverArtist(mbid: hit.mbid ?? 'name:${hit.name}', name: hit.name),
          listeners: hit.listeners,
        );
      }
    }
  }

  /// MusicBrainz ids for artists we already have, from the recordings' credits.
  void addRecordingArtists(List<MbRecording> recordings) {
    for (final recording in recordings) {
      final mbid = recording.artistMbid;
      if (mbid == null) continue;
      final existing = _artists[SearchText.squash(SearchText.primaryArtist(recording.artistName))];
      if (existing != null && !existing.artist.hasMbid) existing.artist = _withMbid(existing.artist, mbid);
    }
  }

  static DiscoverArtist _withMbid(DiscoverArtist artist, String mbid) => DiscoverArtist(
    mbid: mbid,
    name: artist.name,
    imageUrl: artist.imageUrl,
    backdropUrl: artist.backdropUrl,
    reason: artist.reason,
    deezerId: artist.deezerId,
  );

  // ---- Into the index.

  void indexInto({
    required MusicSearchIndex<ChartTrack> songs,
    required MusicSearchIndex<DiscoverAlbum> albums,
    required MusicSearchIndex<DiscoverArtist> artists,
    String? artistBoost,
  }) {
    double artistPopularity(String name) =>
        _artists[SearchText.squash(SearchText.primaryArtist(name))]?.popularity ??
        artists[_artistKey(name)]?.popularity ??
        0;

    for (final song in _songs) {
      final track = song.track;
      // A song nobody's counted borrows a little from its artist.
      final popularity = max(song.popularity, artistPopularity(track.artistName) * 0.6);
      final albumKey = SearchText.albumKey(track.album.artistName, track.album.title);
      _albumPopularity[albumKey] = max(_albumPopularity[albumKey] ?? 0, popularity);
      // The song's album is an album result too (singles especially).
      _putAlbum(track.album);
      songs.put(
        SearchDoc(
          key: 'song:${song.key}',
          value: track,
          fields: [(track.title, 1), (track.artistName, 0.9), (track.album.title, 0.55)],
          popularity: popularity,
          trending: trending.songs[song.key] ?? 0,
        ),
      );
    }
    for (final entry in _albums.entries) {
      final album = entry.value;
      final popularity = max(_albumPopularity[entry.key] ?? 0, artistPopularity(album.artistName) * 0.7);
      albums.put(
        SearchDoc(
          key: 'album:${entry.key}',
          value: album,
          fields: [(album.title, 1), (album.artistName, 0.9)],
          popularity: popularity,
          trending: trending.artists[SearchText.squash(SearchText.primaryArtist(album.artistName))] ?? 0,
        ),
      );
    }
    for (final entry in _artists.entries) {
      artists.put(
        SearchDoc(
          key: _artistKey(entry.value.artist.name),
          value: entry.value.artist,
          fields: [(entry.value.artist.name, 1)],
          popularity: entry.value.popularity,
          trending: trending.artists[entry.key] ?? 0,
        ),
      );
    }
    if (artistBoost != null) {
      // Searching the artist's own name finds their catalogue right after.
      final key = _artistKey(artistBoost);
      final doc = artists[key];
      if (doc != null) doc.popularity = max(doc.popularity, 0.5);
    }
  }

  static String _artistKey(String name) => 'artist:${SearchText.squash(name)}';
}
