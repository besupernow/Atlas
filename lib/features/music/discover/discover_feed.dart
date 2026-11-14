import 'package:flutter/widgets.dart';

import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../data/music_catalog.dart';
import 'allseerr_music.dart';
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
  static void invalidate() => _index = null;

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

  /// Artists like the ones this person plays most, with the reason.
  Future<({String artist, List<MusicFeedItem> items})?> moreLike({int rank = 0}) async {
    final lb = listenBrainz;
    final seerr = allseerr;
    if (lb == null || seerr == null) return null;
    final top = await quietly(lb.topArtists(count: rank + 1), const <({String mbid, String name})>[], 'top artists');
    if (top.length <= rank) return null;
    final artist = top[rank];
    final similar = await quietly(seerr.similarArtists(artist.mbid), const <DiscoverArtist>[], 'similar artists');
    return (artist: artist.name, items: [for (final a in similar) ExternalArtistItem(a)]);
  }

  /// New albums from artists this person plays (ListenBrainz).
  Future<List<MusicFeedItem>> newForYou() async {
    final lb = listenBrainz;
    if (lb == null) return const [];
    final albums = await quietly(lb.freshReleases(), const <ListenBrainzAlbum>[], 'fresh releases for you');
    return resolve([for (final album in albums) album.toDiscover()], known: await known(), limit: 30);
  }

  /// New albums and EPs everywhere (Allseerr, from ListenBrainz).
  Future<List<MusicFeedItem>> newReleases({int pages = 2}) async {
    final seerr = allseerr;
    if (seerr == null) return const [];
    final lists = await Future.wait([
      for (var page = 1; page <= pages; page++)
        quietly(seerr.freshReleases(page: page), const <DiscoverAlbum>[], 'new releases'),
    ]);
    return resolve([for (final list in lists) ...list], limit: 40);
  }

  /// What everyone's playing this week.
  Future<List<MusicFeedItem>> popularAlbums() async {
    final seerr = allseerr;
    if (seerr == null) return const [];
    return resolve(await quietly(seerr.topAlbums(), const <DiscoverAlbum>[], 'popular albums'), limit: 20);
  }

  Future<List<MusicFeedItem>> trendingArtists() async {
    final seerr = allseerr;
    if (seerr == null) return const [];
    final artists = await quietly(seerr.topArtists(), const <DiscoverArtist>[], 'trending artists');
    return [for (final artist in artists) ExternalArtistItem(artist)];
  }

  /// An artist's discography as cards (server copies where we have them).
  Future<List<MusicFeedItem>> discography(String artistMbid) async {
    final seerr = allseerr;
    if (seerr == null) return const [];
    final albums = await seerr.discography(artistMbid);
    return resolve(albums, limit: 200);
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
  });

  final String id;
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
