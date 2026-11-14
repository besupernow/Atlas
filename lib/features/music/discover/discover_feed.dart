import 'package:flutter/widgets.dart';

import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import 'allseerr_music.dart';
import 'deezer.dart';
import 'discover_models.dart';
import 'listenbrainz.dart';

/// Atlas: puts the outside world and the server together. Albums from ListenBrainz and
/// Allseerr become cards for the server's own copy when we have it, and stay "not on the
/// server" cards (with a preview and a request button) when we don't.
class MusicDiscovery {
  MusicDiscovery._(this.catalog, this.allseerr, this.listenBrainz);

  final MusicCatalog catalog;
  final AllseerrMusic? allseerr;
  final ListenBrainz? listenBrainz;

  static MusicDiscovery of(BuildContext context) {
    final username = ListenBrainzAccount.username(context);
    return MusicDiscovery._(
      MusicCatalog.of(context),
      AllseerrMusic.of(context),
      username == null ? null : ListenBrainz(username),
    );
  }

  bool get canDiscover => allseerr != null || listenBrainz != null;

  // ---- The server's albums, indexed by artist and title (shared, refreshed every 10 minutes).

  static Future<Map<String, MediaItem>>? _index;
  static DateTime _indexedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Forget the server index (after a refresh or a finished request).
  static void invalidate() {
    _index = null;
    _artistIndex = null;
  }

  Future<Map<String, MediaItem>> _serverAlbums() {
    final stale = DateTime.now().difference(_indexedAt) > const Duration(minutes: 10);
    if (_index == null || stale) {
      _indexedAt = DateTime.now();
      _index = _loadIndex().catchError((Object _) {
        _index = null;
        return <String, MediaItem>{};
      });
    }
    return _index!;
  }

  Future<Map<String, MediaItem>> _loadIndex() async {
    final index = <String, MediaItem>{};
    for (var offset = 0; offset < 20000;) {
      final page = await catalog.page(MediaKind.album, offset: offset, size: 500);
      for (final album in page.items) {
        index[albumKey(album.albumArtistTitle ?? '', album.title ?? '')] = album;
        index.putIfAbsent(albumKey('', album.title ?? ''), () => album);
      }
      if (!page.hasMore || page.items.isEmpty) break;
      offset += page.items.length;
    }
    return index;
  }

  static String _normal(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\((deluxe|expanded|remaster|anniversary|bonus)[^)]*\)|\[[^\]]*\]'), '')
      .replaceAll('&', 'and')
      .replaceAll(RegExp(r'^the '), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String albumKey(String artist, String title) => '${_normal(artist)}|${_normal(title)}';

  /// The server's copy of [album], if it has one.
  Future<MediaItem?> serverCopy(DiscoverAlbum album) async {
    final index = await _serverAlbums();
    return index[albumKey(album.artistName, album.title)] ??
        (album.status.onServer ? index[albumKey('', album.title)] : null);
  }

  /// Cards for [albums]: the server's copy where there is one, otherwise the album itself with
  /// what Allseerr knows about it.
  Future<List<MusicFeedItem>> resolve(
      List<DiscoverAlbum> albums, {
        Map<String, DiscoverStatus> known = const {},
        bool serverOnly = false,
        bool externalOnly = false,
        int limit = 20,
      }) async {
    final index = await _serverAlbums();
    final seen = <String>{};
    final items = <MusicFeedItem>[];
    for (final album in albums) {
      if (items.length >= limit) break;
      if (!seen.add(album.mbid)) continue;
      final status = StatusOverrides.instance.statusOf(album.mbid) ?? known[album.mbid] ?? album.status;
      final copy =
          index[albumKey(album.artistName, album.title)] ?? (status.onServer ? index[albumKey('', album.title)] : null);
      if (copy != null) {
        if (!externalOnly) items.add(ServerFeedItem(copy, reason: album.reason));
      } else if (!serverOnly) {
        items.add(ExternalAlbumItem(album.copyWith(status: status)));
      }
    }
    return items;
  }

  Map<String, DiscoverStatus>? _known;

  Future<Map<String, DiscoverStatus>> known() async {
    final cached = _known;
    if (cached != null) return cached;
    final seerr = allseerr;
    final fetched = seerr == null
        ? const <String, DiscoverStatus>{}
        : await quietly(seerr.knownAlbums(), const <String, DiscoverStatus>{}, 'known albums');
    _known = fetched;
    return fetched;
  }

  // ---- Rows.

  /// ListenBrainz's picks for this person (collaborative filtering, then Weekly Exploration),
  /// as albums.
  Future<List<DiscoverAlbum>> recommendations() async {
    final lb = listenBrainz;
    if (lb == null) return const [];
    final results = await Future.wait([
      quietly(lb.recommendedAlbums(), const <ListenBrainzAlbum>[], 'recommendations'),
      quietly(lb.weeklyExplorationAlbums(), const <ListenBrainzAlbum>[], 'weekly exploration'),
    ]);
    // Interleave so both sources show up near the front.
    final merged = <ListenBrainzAlbum>[];
    for (var i = 0; i < results[0].length || i < results[1].length; i++) {
      if (i < results[0].length) merged.add(results[0][i]);
      if (i < results[1].length) merged.add(results[1][i]);
    }
    return [for (final album in merged) album.toDiscover()];
  }

  /// Albums on the server picked for this person: the server copies of ListenBrainz's picks,
  /// topped up with albums nobody's played yet. (AudioMuse-AI will sharpen this.)
  Future<List<MusicFeedItem>> pickedForYou(List<DiscoverAlbum> recommendations) async {
    final fromRecs = await resolve(recommendations, serverOnly: true, limit: 12);
    if (fromRecs.length >= 12) return fromRecs;
    final unplayed = await quietly(
      catalog.items(MediaKind.album, sort: 'random', limit: 60),
      const <MediaItem>[],
      'unplayed albums',
    );
    final seen = {for (final item in fromRecs) item.key};
    return [
      ...fromRecs,
      for (final album in unplayed)
        if ((album.viewCount ?? 0) == 0 && seen.add('server:${album.globalKey}')) ServerFeedItem(album),
    ].take(16).toList();
  }

  // ---- The server's artists, by name (for marking related artists we already have).

  static Future<Map<String, MediaItem>>? _artistIndex;

  Future<Map<String, MediaItem>> _serverArtists() {
    return _artistIndex ??= () async {
      final index = <String, MediaItem>{};
      try {
        for (var offset = 0; offset < 20000;) {
          final page = await catalog.page(MediaKind.artist, offset: offset, size: 500);
          for (final artist in page.items) {
            index[Deezer.normal(artist.title ?? '')] = artist;
          }
          if (!page.hasMore || page.items.isEmpty) break;
          offset += page.items.length;
        }
      } catch (_) {
        _artistIndex = null;
      }
      return index;
    }();
  }

  /// Cards for [artists]: the server's artist page where we have them.
  Future<List<MusicFeedItem>> resolveArtists(List<DiscoverArtist> artists, {int limit = 30}) async {
    final index = await _serverArtists();
    final seen = <String>{};
    return [
      for (final artist in artists)
        if (seen.add(Deezer.normal(artist.name)))
          if (index[Deezer.normal(artist.name)] case final server?)
            ServerFeedItem(server, reason: artist.reason)
          else
            ExternalArtistItem(artist),
    ].take(limit).toList();
  }

  // ---- Who this person listens to.

  Future<List<DiscoverArtist>>? _seeds;

  /// The artists this person plays most: ListenBrainz's stats when connected, otherwise the
  /// server's play counts, otherwise a few artists from the server.
  Future<List<DiscoverArtist>> seeds({int count = 3}) => _seeds ??= () async {
    final names = <String>[];
    final lb = listenBrainz;
    if (lb != null) {
      final top = await quietly(lb.topArtists(count: count), const <({String mbid, String name})>[], 'top artists');
      names.addAll(top.map((artist) => artist.name));
    }
    if (names.length < count) {
      final played = await quietly(catalog.mostPlayed(limit: 60), const <MediaItem>[], 'most played');
      for (final track in played) {
        final name = track.albumArtistTitle ?? track.trackArtistTitle;
        if (name != null && name.isNotEmpty && !names.contains(name)) names.add(name);
        if (names.length >= count) break;
      }
    }
    if (names.length < count) {
      final artists = await quietly(catalog.items(MediaKind.artist, sort: 'random', limit: count), const <MediaItem>[], 'artists');
      for (final artist in artists) {
        final name = artist.title;
        if (name != null && name.isNotEmpty && !names.contains(name)) names.add(name);
      }
    }
    return [for (final name in names.take(count)) DiscoverArtist(mbid: 'name:$name', name: name)];
  }();

  /// Albums artists like yours are known for (Deezer's related artists), with why.
  Future<List<DiscoverAlbum>> similarAlbums() async {
    final seeds = await this.seeds();
    final perSeed = await Future.wait([
      for (final seed in seeds)
        () async {
          final related = await quietly(Deezer.related(seed, limit: 8), const <DiscoverArtist>[], 'related artists');
          final albums = await Future.wait([
            for (final artist in related.take(5))
              quietly(Deezer.signatureAlbum(artist, reason: MusicStrings.likeArtist(seed.name)), null, 'top album'),
          ]);
          return albums.whereType<DiscoverAlbum>().toList();
        }(),
    ]);
    // Round-robin so every seed shows up early.
    final merged = <DiscoverAlbum>[];
    for (var i = 0; perSeed.any((list) => i < list.length); i++) {
      for (final list in perSeed) {
        if (i < list.length) merged.add(list[i]);
      }
    }
    return merged;
  }

  /// Recommended for You: ListenBrainz's picks and albums like your artists', on the server or
  /// not (yet).
  Future<List<MusicFeedItem>> recommended(List<DiscoverAlbum> listenBrainzPicks, {int limit = 30}) async {
    final similar = await quietly(similarAlbums(), const <DiscoverAlbum>[], 'similar albums');
    final merged = <DiscoverAlbum>[];
    final seen = <String>{};
    for (var i = 0; i < listenBrainzPicks.length || i < similar.length; i++) {
      for (final album in [if (i < listenBrainzPicks.length) listenBrainzPicks[i], if (i < similar.length) similar[i]]) {
        if (seen.add(albumKey(album.artistName, album.title))) merged.add(album);
      }
    }
    return resolve(merged, known: await known(), limit: limit);
  }

  /// Artists like the one this person plays most (or the [rank]th), with the name.
  Future<({String artist, List<MusicFeedItem> items})?> moreLike({int rank = 0}) async {
    final seeds = await this.seeds();
    if (seeds.length <= rank) return null;
    final seed = seeds[rank];
    final related = await quietly(Deezer.related(seed, limit: 20), const <DiscoverArtist>[], 'related artists');
    if (related.isEmpty) return null;
    return (artist: seed.name, items: await resolveArtists(related));
  }

  /// New albums from artists this person plays (ListenBrainz).
  Future<List<MusicFeedItem>> newForYou() async {
    final lb = listenBrainz;
    if (lb == null) return const [];
    final albums = await quietly(lb.freshReleases(), const <ListenBrainzAlbum>[], 'fresh releases for you');
    return resolve([for (final album in albums) album.toDiscover()], known: await known(), limit: 30);
  }

  /// This week's new releases (Deezer's editors).
  Future<List<MusicFeedItem>> newReleases({int limit = 60}) async =>
      resolve(await Deezer.newReleases(limit: limit), limit: limit);

  /// The most played albums right now, in chart order.
  Future<List<MusicFeedItem>> topAlbums({int limit = 50}) async =>
      resolve(await Deezer.topAlbums(limit: limit), limit: limit);

  /// The most played artists right now.
  Future<List<MusicFeedItem>> topArtists() async => resolveArtists(await Deezer.topArtists());

  /// An artist's releases as cards (server copies where we have them).
  Future<List<MusicFeedItem>> discographyOf(DiscoverArtist artist) async {
    var albums = await quietly(Deezer.albumsBy(artist), const <DiscoverAlbum>[], 'discography');
    final seerr = allseerr;
    if (albums.isEmpty && seerr != null && artist.hasMbid && !artist.mbid.startsWith('name:')) {
      albums = await quietly(seerr.discography(artist.mbid), const <DiscoverAlbum>[], 'discography');
    }
    return resolve(albums, limit: 200);
  }

  /// Artists like [artist].
  Future<List<MusicFeedItem>> similarTo(DiscoverArtist artist) async {
    var related = await quietly(Deezer.related(artist), const <DiscoverArtist>[], 'related artists');
    final seerr = allseerr;
    if (related.isEmpty && seerr != null && artist.hasMbid && !artist.mbid.startsWith('name:')) {
      related = await quietly(seerr.similarArtists(artist.mbid), const <DiscoverArtist>[], 'similar artists');
    }
    return resolveArtists(related);
  }

  static List<MusicFeedItem> server(List<MediaItem> items) => [for (final item in items) ServerFeedItem(item)];
}

/// A row on a discovery page, loaded on its own.
class MusicFeedRow {
  const MusicFeedRow({
    required this.id,
    required this.title,
    this.subtitle,
    this.items = const [],
    this.large = false,
    this.seeAll,
    this.custom,
    this.kicker,
    this.ranked = false,
  });

  final String id;

  /// The small colored word above the title ("THIS WEEK", "FOR YOU").
  final String? kicker;

  /// Chart order: big numbers beside the cards.
  final bool ranked;
  final String title;
  final String? subtitle;
  final List<MusicFeedItem> items;

  /// Bigger cards (the first rows of a page).
  final bool large;

  /// Loads the full list for the header's ">" (Apple's "see all").
  final Future<List<MusicFeedItem>> Function()? seeAll;

  /// A row that draws itself (Top Picks, Made for You). Given the "focus the rail" callback.
  final Widget Function(BuildContext context, VoidCallback? focusRail)? custom;

  bool get isEmpty => custom == null && items.isEmpty;
}
