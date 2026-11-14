import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../media/ids.dart';
import '../../../media/library_genre.dart';
import '../../../media/library_query.dart';
import '../../../media/media_filter.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../media/media_library.dart';
import '../../../media/media_playlist.dart';
import '../../../media/media_server_client.dart';
import '../../../providers/libraries_provider.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/provider_extensions.dart';

/// One music library and the client for its server.
class MusicSource {
  const MusicSource(this.client, this.library);

  final MediaServerClient client;
  final MediaLibrary library;
}

/// A genre and the libraries that have it.
class MusicGenre {
  const MusicGenre(this.title, this.filterValues);

  final String title;

  /// Per library id, the value to filter that library by.
  final Map<String, String> filterValues;
}

/// Atlas: everything music mode reads from the servers: albums, artists, songs, genres,
/// playlists and search, merged across every music library the user can see. Each library is
/// asked on its own, so one failing server doesn't empty a page.
class MusicCatalog {
  MusicCatalog(this.sources);

  final List<MusicSource> sources;

  static MusicCatalog of(BuildContext context) {
    final libraries = context.read<LibrariesProvider>().musicLibraries;
    return MusicCatalog([
      for (final library in libraries)
        if (context.tryGetMediaClientForServer(serverIdOrNull(library.serverId)) case final client?)
          MusicSource(client, library),
    ]);
  }

  bool get isEmpty => sources.isEmpty;

  /// Items of [kind] from every library, merged, at most [limit].
  Future<List<MediaItem>> items(
      MediaKind kind, {
        String? sort,
        LibrarySortDirection direction = LibrarySortDirection.descending,
        List<LibraryFilter> filters = const [],
        int limit = 30,
        String? search,
      }) async {
    final query = LibraryQuery(
      kind: kind,
      limit: limit,
      sort: sort == null ? null : LibrarySort(field: sort, direction: direction),
      filters: filters,
      search: search,
    );
    final pages = await Future.wait([
      for (final source in sources)
        source.client
            .fetchLibraryPagedContent(source.library.id, query: query, libraryKind: source.library.kind)
            .then((page) => page.items)
            .catchError((Object error) {
          appLogger.w('Music: ${kind.name} from ${source.library.title} failed', error: error);
          return const <MediaItem>[];
        }),
    ]);
    final merged = [for (final page in pages) ...page];
    if (pages.length > 1 && sort != null) merged.sort((a, b) => _compare(a, b, sort, direction));
    return merged.length > limit ? merged.sublist(0, limit) : merged;
  }

  /// One page of [kind] for the library lists: [offset] counts across all libraries in order.
  Future<({List<MediaItem> items, bool hasMore})> page(
      MediaKind kind, {
        required int offset,
        int size = 100,
        String sort = 'title',
        LibrarySortDirection direction = LibrarySortDirection.ascending,
        List<LibraryFilter> Function(MusicSource source)? filtersFor,
      }) async {
    var skip = offset;
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final filters = filtersFor?.call(source);
      if (filtersFor != null && (filters == null || filters.isEmpty)) continue;
      final query = LibraryQuery(
        kind: kind,
        offset: skip,
        limit: size,
        sort: LibrarySort(field: sort, direction: direction),
        filters: filters ?? const [],
      );
      final result = await source.client.fetchLibraryPagedContent(
        source.library.id,
        query: query,
        libraryKind: source.library.kind,
      );
      if (skip >= result.totalCount) {
        skip -= result.totalCount;
        continue;
      }
      final moreHere = skip + result.items.length < result.totalCount;
      return (items: result.items, hasMore: moreHere || i < sources.length - 1);
    }
    return (items: const <MediaItem>[], hasMore: false);
  }

  Future<List<MediaItem>> recentlyAddedAlbums({int limit = 24}) => items(MediaKind.album, sort: 'addedAt', limit: limit);

  /// Newest releases by release date.
  Future<List<MediaItem>> newReleases({int limit = 30}) =>
      items(MediaKind.album, sort: 'originallyAvailableAt', limit: limit);

  /// Recently played songs, one per album.
  Future<List<MediaItem>> recentlyPlayed({int limit = 20}) async {
    final tracks = await items(MediaKind.track, sort: 'lastViewedAt', limit: limit * 4);
    final seen = <String>{};
    return [
      for (final track in tracks)
        if ((track.lastViewedAt ?? 0) > 0 && seen.add(track.parentId ?? track.id)) track,
    ].take(limit).toList();
  }

  /// Most played songs (only ones played at least once).
  Future<List<MediaItem>> mostPlayed({int limit = 20}) async {
    final tracks = await items(MediaKind.track, sort: 'viewCount', limit: limit);
    return [for (final track in tracks) if ((track.viewCount ?? 0) > 0) track];
  }

  Future<List<MediaItem>> favoriteAlbums({int limit = 24}) => items(
    MediaKind.album,
    sort: 'addedAt',
    limit: limit,
    filters: const [LibraryFilter(field: MediaFilterField.favorite, values: ['1'])],
  );

  /// Artists for radio stations: the ones behind the most played songs first, then a random
  /// handful so there's always something.
  Future<List<MediaItem>> stationArtists({int limit = 12}) async {
    final played = await mostPlayed(limit: 40);
    final names = <String>{for (final track in played) ?track.albumArtistTitle};
    final artists = await items(MediaKind.artist, sort: 'random', limit: 60);
    artists.sort((a, b) {
      final aPlayed = names.contains(a.title) ? 0 : 1;
      final bPlayed = names.contains(b.title) ? 0 : 1;
      return aPlayed.compareTo(bPlayed);
    });
    return artists.take(limit).toList();
  }

  Future<List<MusicGenre>> genres() async {
    final byTitle = <String, Map<String, String>>{};
    await Future.wait([
      for (final source in sources)
        source.client
            .fetchLibraryGenres(source.library.id, libraryKind: source.library.kind)
            .then((genres) {
          for (final LibraryGenre genre in genres) {
            (byTitle[genre.title] ??= {})[source.library.id] = genre.filterValue;
          }
        })
            .catchError((Object error) {
          appLogger.w('Music: genres from ${source.library.title} failed', error: error);
        }),
    ]);
    final titles = byTitle.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final title in titles) MusicGenre(title, byTitle[title]!)];
  }

  List<LibraryFilter> genreFilters(MusicGenre genre, MusicSource source) {
    final value = genre.filterValues[source.library.id];
    return value == null ? const [] : [LibraryFilter(field: MediaFilterField.genre, values: [value])];
  }

  /// A shuffled selection of songs in [genre], for a genre station.
  Future<List<MediaItem>> genreTracks(MusicGenre genre, {int limit = 100}) async {
    final pages = await Future.wait([
      for (final source in sources)
        if (genre.filterValues.containsKey(source.library.id))
          source.client
              .fetchLibraryPagedContent(
            source.library.id,
            query: LibraryQuery(
              kind: MediaKind.track,
              limit: limit,
              sort: const LibrarySort(field: 'random'),
              filters: genreFilters(genre, source),
            ),
            libraryKind: source.library.kind,
          )
              .then((page) => page.items)
              .catchError((Object error) {
            appLogger.w('Music: ${genre.title} songs from ${source.library.title} failed', error: error);
            return const <MediaItem>[];
          }),
    ]);
    return [for (final page in pages) ...page]..shuffle();
  }

  /// A song to start "Your Station" from: the most played one, or any song.
  Future<MediaItem?> stationSeed() async {
    final played = await mostPlayed(limit: 5);
    if (played.isNotEmpty) return (played.toList()..shuffle()).first;
    final any = await items(MediaKind.track, sort: 'random', limit: 1);
    return any.isEmpty ? null : any.first;
  }

  /// Audio playlists from every server with music.
  Future<List<MediaPlaylist>> playlists() async {
    final clients = {for (final source in sources) source.client.serverId: source.client}.values;
    final pages = await Future.wait([
      for (final client in clients)
        client
            .fetchPlaylistsPage(playlistType: 'audio', size: 200)
            .then((page) => page.items)
            .catchError((Object error) {
          appLogger.w('Music: playlists failed', error: error);
          return const <MediaPlaylist>[];
        }),
    ]);
    return [for (final page in pages) ...page];
  }

  /// Music search results grouped Apple Music style.
  Future<MusicSearchResults> search(String query) async {
    final clients = {for (final source in sources) source.client.serverId: source.client}.values;
    final results = await Future.wait([
      for (final client in clients)
        client.searchItems(query, limit: 80).catchError((Object error) {
          appLogger.w('Music: search failed', error: error);
          return const <MediaItem>[];
        }),
    ]);
    final all = [
      for (final list in results)
        for (final item in list)
          if (item.kind.isMusic) item,
    ];
    return MusicSearchResults(
      artists: [for (final item in all) if (item.kind == MediaKind.artist) item],
      albums: [for (final item in all) if (item.kind == MediaKind.album) item],
      songs: [for (final item in all) if (item.kind == MediaKind.track) item],
    );
  }

  static int _compare(MediaItem a, MediaItem b, String sort, LibrarySortDirection direction) {
    final int result = switch (sort) {
      'addedAt' => (a.addedAt ?? 0).compareTo(b.addedAt ?? 0),
      'lastViewedAt' => (a.lastViewedAt ?? 0).compareTo(b.lastViewedAt ?? 0),
      'viewCount' => (a.viewCount ?? 0).compareTo(b.viewCount ?? 0),
      'originallyAvailableAt' => (a.originallyAvailableAt ?? '${a.year ?? ''}').compareTo(
        b.originallyAvailableAt ?? '${b.year ?? ''}',
      ),
      'title' => (a.title ?? '').toLowerCase().compareTo((b.title ?? '').toLowerCase()),
      _ => 0,
    };
    return direction == LibrarySortDirection.descending ? -result : result;
  }
}

class MusicSearchResults {
  const MusicSearchResults({required this.artists, required this.albums, required this.songs});

  final List<MediaItem> artists;
  final List<MediaItem> albums;
  final List<MediaItem> songs;

  bool get isEmpty => artists.isEmpty && albums.isEmpty && songs.isEmpty;
}
