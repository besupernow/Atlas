import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../media/media_playlist.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../services/settings_service.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/focusable_media_card.dart';
import '../../../widgets/music/mini_player.dart';
import '../../../widgets/music/track_row.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import '../widgets/music_page.dart';

/// Pages through a music list (artists, albums or songs) 100 at a time.
mixin _PagedMusicList<T extends StatefulWidget> on State<T> {
  final List<MediaItem> items = [];
  bool loading = false;
  bool hasMore = true;
  bool failed = false;

  Future<({List<MediaItem> items, bool hasMore})> fetchPage(MusicCatalog catalog, int offset);

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    setState(() => loading = true);
    try {
      final page = await fetchPage(MusicCatalog.of(context), items.length);
      if (!mounted) return;
      setState(() {
        items.addAll(page.items);
        hasMore = page.hasMore && page.items.isNotEmpty;
        failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Load the next page once the list scrolls near its end.
  bool onScroll(ScrollNotification notification) {
    if (notification.metrics.pixels > notification.metrics.maxScrollExtent - 800) unawaited(loadMore());
    return false;
  }

  Widget footer() {
    if (failed) return const MusicPagePlaceholder(message: MusicStrings.loadFailed);
    if (loading) return const MusicPagePlaceholder();
    if (items.isEmpty && !hasMore) return const MusicPagePlaceholder(message: MusicStrings.nothingYet);
    return const SizedBox.shrink();
  }
}

/// Atlas: every artist or album (optionally in one genre) as a grid of cards.
class MusicItemGridPage extends StatefulWidget {
  const MusicItemGridPage({super.key, required this.kind, required this.title, this.genre});

  final MediaKind kind;
  final String title;
  final MusicGenre? genre;

  @override
  State<MusicItemGridPage> createState() => _MusicItemGridPageState();
}

class _MusicItemGridPageState extends State<MusicItemGridPage> with _PagedMusicList<MusicItemGridPage> {
  @override
  void initState() {
    super.initState();
    unawaited(loadMore());
  }

  @override
  Future<({List<MediaItem> items, bool hasMore})> fetchPage(MusicCatalog catalog, int offset) {
    final genre = widget.genre;
    return catalog.page(
      widget.kind,
      offset: offset,
      filtersFor: genre == null ? null : (source) => catalog.genreFilters(genre, source),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTV = PlatformDetector.isTV();
    final miniPlayerRoom = context.watch<MiniPlayerInsetController?>()?.overlayHeight ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: NotificationListener<ScrollNotification>(
        onNotification: onScroll,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 8)),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: isTV ? 220 : 180,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.78,
                ),
                delegate: SliverChildBuilderDelegate(
                      (context, index) => FocusableMediaCard(
                    item: items[index],
                    viewModeOverride: ViewMode.grid,
                    cardShapeOverride: CardShape.square,
                  ),
                  childCount: items.length,
                ),
              ),
            ),
            SliverToBoxAdapter(child: footer()),
            SliverToBoxAdapter(child: SizedBox(height: 24 + miniPlayerRoom)),
          ],
        ),
      ),
    );
  }
}

/// Atlas: every song, A to Z. Tapping one plays the list from there.
class MusicSongsPage extends StatefulWidget {
  const MusicSongsPage({super.key});

  @override
  State<MusicSongsPage> createState() => _MusicSongsPageState();
}

class _MusicSongsPageState extends State<MusicSongsPage> with _PagedMusicList<MusicSongsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(loadMore());
  }

  @override
  Future<({List<MediaItem> items, bool hasMore})> fetchPage(MusicCatalog catalog, int offset) =>
      catalog.page(MediaKind.track, offset: offset);

  void _play(MediaItem track, {bool shuffle = false}) {
    unawaited(
      playTracks(
        context,
        tracks: List.of(items),
        startTrack: shuffle ? null : track,
        playContext: const MusicPlayContext(title: MusicStrings.songs, kind: MusicPlayContextKind.tracks),
        shuffle: shuffle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final miniPlayerRoom = context.watch<MiniPlayerInsetController?>()?.overlayHeight ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text(MusicStrings.songs),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const AppIcon(Symbols.shuffle_rounded),
              onPressed: () => _play(items.first, shuffle: true),
            ),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: onScroll,
        child: ListView.builder(
          padding: MusicPage.padding(context).add(EdgeInsets.only(top: 8, bottom: 24 + miniPlayerRoom)),
          itemCount: items.length + 1,
          itemBuilder: (context, index) {
            if (index == items.length) return footer();
            final track = items[index];
            return TrackRow(
              item: track,
              showArtist: true,
              showTrackNumber: false,
              isFirst: index == 0,
              isLast: index == items.length - 1,
              onTap: () => _play(track),
            );
          },
        ),
      ),
    );
  }
}

/// Atlas: every genre; each opens its albums.
class MusicGenresPage extends StatefulWidget {
  const MusicGenresPage({super.key});

  @override
  State<MusicGenresPage> createState() => _MusicGenresPageState();
}

class _MusicGenresPageState extends State<MusicGenresPage> {
  List<MusicGenre>? _genres;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final genres = await MusicCatalog.of(context).genres();
      if (mounted) setState(() => _genres = genres);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final genres = _genres;
    final miniPlayerRoom = context.watch<MiniPlayerInsetController?>()?.overlayHeight ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text(MusicStrings.genres)),
      body: genres == null
          ? MusicPagePlaceholder(message: _failed ? MusicStrings.loadFailed : null)
          : genres.isEmpty
          ? const MusicPagePlaceholder(message: MusicStrings.nothingYet)
          : ListView.builder(
        padding: MusicPage.padding(context).add(EdgeInsets.only(top: 8, bottom: 24 + miniPlayerRoom)),
        itemCount: genres.length,
        itemBuilder: (context, index) {
          final genre = genres[index];
          return FocusableListTile(
            autofocus: index == 0 && PlatformDetector.isTV(),
            leading: AppIcon(Symbols.graphic_eq_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text(genre.title),
            trailing: const AppIcon(Symbols.chevron_right_rounded),
            onTap: () => unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MusicItemGridPage(kind: MediaKind.album, title: genre.title, genre: genre),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Atlas: the audio playlists on your servers.
class MusicPlaylistsPage extends StatefulWidget {
  const MusicPlaylistsPage({super.key});

  @override
  State<MusicPlaylistsPage> createState() => _MusicPlaylistsPageState();
}

class _MusicPlaylistsPageState extends State<MusicPlaylistsPage> {
  List<MediaPlaylist>? _playlists;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final playlists = await MusicCatalog.of(context).playlists();
      if (mounted) setState(() => _playlists = playlists);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = _playlists;
    final isTV = PlatformDetector.isTV();
    final miniPlayerRoom = context.watch<MiniPlayerInsetController?>()?.overlayHeight ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text(MusicStrings.playlists)),
      body: playlists == null
          ? MusicPagePlaceholder(message: _failed ? MusicStrings.loadFailed : null)
          : playlists.isEmpty
          ? const MusicPagePlaceholder(message: MusicStrings.nothingYet)
          : GridView.builder(
        padding: MusicPage.padding(context).add(EdgeInsets.only(top: 8, bottom: 24 + miniPlayerRoom)),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: isTV ? 220 : 180,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.78,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, index) => FocusableMediaCard(
          item: playlists[index],
          viewModeOverride: ViewMode.grid,
          cardShapeOverride: CardShape.square,
        ),
      ),
    );
  }
}
