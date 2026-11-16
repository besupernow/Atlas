import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_action_bar.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../media/artist_discography.dart';
import '../../../media/ids.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../media/media_server_client.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../utils/media_image_helper.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/provider_extensions.dart';
import '../../../widgets/collapsible_text.dart';
import '../../../widgets/music/music_actions.dart';
import '../../../widgets/music/track_row.dart';
import '../../../widgets/optimized_media_image.dart';
import '../discover/allseerr_music.dart';
import '../discover/deezer.dart';
import '../discover/discover_feed.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import '../discover/music_previews.dart';
import '../discover/music_search_index.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/art_backdrop.dart';
import '../widgets/music_item_menu.dart';
import '../widgets/music_page.dart';

/// Atlas: an Apple Music style artist page: full-bleed artwork fading into the page with the
/// name over it, Play / Shuffle / Station, the five songs played most, the discography split
/// into Albums, Singles & EPs, Live and Compilations, similar artists, then what isn't on the
/// server yet (their popular songs and releases, to preview and request), then the bio.
class MusicArtistPage extends StatefulWidget {
  const MusicArtistPage({super.key, required this.artist});

  final MediaItem artist;

  @override
  State<MusicArtistPage> createState() => _MusicArtistPageState();
}

class _MusicArtistPageState extends State<MusicArtistPage> {
  final _actionsKey = GlobalKey<FocusableActionBarState>();
  final _firstSongFocus = FocusNode(debugLabel: 'music.artist.topSong');

  MediaServerClient? _client;
  List<MediaItem>? _allTracks;
  List<MediaItem> _topSongs = const [];
  List<ArtistDiscographyGroup> _discography = const [];
  List<MediaItem> _similar = const [];
  bool _failed = false;

  // The artist's real top songs (Deezer's chart of them), each ours when the server has it.
  List<_ArtistSong> _popular = const [];

  // What isn't on the server: releases and similar artists, mixed into the sections below.
  List<ExternalAlbumItem> _outsideReleases = const [];
  List<MusicFeedItem> _outsideSimilar = const [];

  MediaItem get _artist => widget.artist;

  @override
  void initState() {
    super.initState();
    _client = context.tryGetMediaClientWithFallback(serverIdOrNull(_artist.serverId));
    unawaited(_load());
    if (PlatformDetector.isTV()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _actionsKey.currentState?.requestFocusOnFirst());
    }
  }

  @override
  void dispose() {
    _firstSongFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) {
      _failed = true;
      _allTracks = const [];
      return;
    }
    // Each part loads on its own so a missing "similar" hub doesn't blank the page.
    final discography = client.fetchArtistDiscography(_artist).catchError((Object _) => <ArtistDiscographyGroup>[]);
    final tracks = client.fetchPlayableDescendants(_artist.id).catchError((Object _) => <MediaItem>[]);
    final similar = client
        .fetchRelatedHubs(_artist.id)
        .then((hubs) => [
      for (final hub in hubs)
        for (final item in hub.items)
          if (item.kind == MediaKind.artist && item.id != _artist.id) item,
    ])
        .catchError((Object _) => <MediaItem>[]);

    final groups = await discography;
    final all = await tracks;
    final related = await similar;
    if (!mounted) return;
    setState(() {
      _discography = groups;
      _allTracks = all;
      _topSongs = _pickTopSongs(all);
      _similar = {for (final artist in related) artist.id: artist}.values.take(15).toList();
      _failed = groups.isEmpty && all.isEmpty;
    });
    unawaited(_loadOutside(all));
  }

  /// What the rest of the world has by this artist (Deezer, through discovery): their actual
  /// top songs (ours where the server has them) and the releases and similar artists the server
  /// doesn't have, which join the sections with a request button.
  Future<void> _loadOutside(List<MediaItem> ours) async {
    final discovery = MusicDiscovery.of(context);
    final name = _artist.displayTitle;
    final artist = await quietly(Deezer.findArtist(name), null, 'artist on Deezer');
    if (artist == null || !mounted) return;
    final results = await Future.wait<Object?>([
      quietly(Deezer.topTracksOf(artist, limit: 10), const <ChartTrack>[], 'artist top songs'),
      quietly(discovery.discographyOf(artist), const <MusicFeedItem>[], 'artist releases'),
      quietly(discovery.similarTo(artist), const <MusicFeedItem>[], 'similar artists'),
    ]);
    if (!mounted) return;
    final byTitle = <String, MediaItem>{};
    for (final track in ours) {
      byTitle.putIfAbsent(SearchText.squash(SearchText.cleanTitle(track.title ?? '')), () => track);
    }
    final popular = <_ArtistSong>[
      for (final track in results[0] as List<ChartTrack>)
        if (byTitle[SearchText.squash(SearchText.cleanTitle(track.title))] case final server?)
          _ArtistSong(track, server)
        // Songs from outside only show when they can be previewed.
        else if (track.previewUrl != null)
          _ArtistSong(track, null),
    ];
    final similarNames = {for (final artist in _similar) SearchText.squash(artist.title ?? '')};
    setState(() {
      _popular = popular;
      _outsideReleases = [
        for (final item in results[1] as List<MusicFeedItem>)
          if (item is ExternalAlbumItem) item,
      ];
      _outsideSimilar = [
        for (final item in results[2] as List<MusicFeedItem>)
          if (item is! ExternalArtistItem || !similarNames.contains(SearchText.squash(item.artist.name))) item,
      ];
    });
  }

  /// The server's releases of [kind] with the outside ones of the same kind, newest first.
  List<MusicFeedItem> _section(DiscographyGroupKind kind) {
    final server = [
      for (final group in _discography)
        if (group.kind == kind)
          for (final item in group.items) item,
    ];
    // Anything the server has (under any section) isn't shown again from outside.
    final ours = {
      for (final group in _discography)
        for (final item in group.items) SearchText.squash(SearchText.cleanTitle(item.title ?? '')),
    };
    final outside = [
      for (final item in _outsideReleases)
        if (_kindOf(item.album) == kind && !ours.contains(SearchText.squash(SearchText.cleanTitle(item.album.title))))
          item,
    ];
    final items = <(String, MusicFeedItem)>[
      for (final item in server) ('${item.albumYear ?? item.year ?? ''}', ServerFeedItem(item)),
      for (final item in outside) (item.album.releaseDate ?? item.album.year ?? '', item),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final (_, item) in items) item];
  }

  static DiscographyGroupKind _kindOf(DiscoverAlbum album) => switch (album.type?.toLowerCase()) {
    'single' || 'ep' => DiscographyGroupKind.singlesAndEps,
    'compilation' => DiscographyGroupKind.compilations,
    'live' => DiscographyGroupKind.live,
    _ => DiscographyGroupKind.albums,
  };

  /// Most played first; with nothing played yet, the newest album's opening tracks.
  static List<MediaItem> _pickTopSongs(List<MediaItem> tracks) {
    final played = [for (final track in tracks) if ((track.viewCount ?? 0) > 0) track]
      ..sort((a, b) => (b.viewCount ?? 0).compareTo(a.viewCount ?? 0));
    final picks = [...played.take(5)];
    for (final track in tracks) {
      if (picks.length >= 5) break;
      if (!picks.contains(track)) picks.add(track);
    }
    return picks;
  }

  void _playAll({bool shuffle = false}) {
    final tracks = _allTracks;
    final playContext = MusicPlayContext(title: _artist.displayTitle, kind: MusicPlayContextKind.artist);
    if (tracks != null && tracks.isNotEmpty) {
      unawaited(playTracks(context, tracks: tracks, playContext: playContext, shuffle: shuffle));
      return;
    }
    final client = _client;
    if (client == null) return;
    unawaited(
      playFetchedTracks(
        context,
        fetch: () => client.fetchPlayableDescendants(_artist.id),
        playContext: playContext,
        shuffle: shuffle,
      ),
    );
  }

  void _playTopSong(MediaItem track) {
    final ours = _popular.isEmpty ? _topSongs : [for (final song in _popular) ?song.server];
    unawaited(
      playTracks(
        context,
        tracks: ours,
        startTrack: track,
        playContext: MusicPlayContext(title: _artist.displayTitle, kind: MusicPlayContextKind.artist),
      ),
    );
  }

  String _groupTitle(DiscographyGroupKind kind) => switch (kind) {
    DiscographyGroupKind.albums => MusicStrings.albumsSection,
    DiscographyGroupKind.singlesAndEps => MusicStrings.singlesAndEps,
    DiscographyGroupKind.live => MusicStrings.live,
    DiscographyGroupKind.compilations => MusicStrings.compilations,
  };

  void _focusBelowActions() => _firstSongFocus.requestFocus();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTV = PlatformDetector.isTV();
    final focus = MusicShellFocus.maybeOf(context);
    final summary = _artist.summary;
    final loading = _allTracks == null;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: isTV
          ? null
          : AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ArtBackdrop(
        image: OptimizedMediaImage(
          client: _client,
          imagePath: _artist.thumbPath,
          imageType: ImageType.square,
          fit: BoxFit.cover,
        ),
        child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _ArtistHero(artist: _artist, client: _client),
          Padding(
            padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 4, bottom: 8)),
            child: FocusableActionBar(
              key: _actionsKey,
              spacing: 4,
              actions: buildMusicActions(
                onPlay: _playAll,
                onShuffle: () => _playAll(shuffle: true),
                onInstantMix: (_client?.capabilities.instantMix ?? false)
                    ? () => unawaited(playInstantMix(context, _artist))
                    : null,
              ),
              onNavigateDown: _focusBelowActions,
              onNavigateLeft: focus?.focusRail,
              onBack: () => Navigator.maybePop(context),
            ),
          ),
          if (loading)
            const MusicPagePlaceholder()
          else if (_failed)
            const MusicPagePlaceholder(message: MusicStrings.loadFailed)
          else ...[
              // Top Songs: their real chart, ours where we have it (play), the rest previews
              // with a request button. Before the outside chart loads, the server's own.
              if (_popular.isNotEmpty) ...[
                const MusicSectionTitle(MusicStrings.topSongs),
                Padding(
                  padding: MusicPage.padding(context),
                  child: Column(
                    children: [
                      for (final (index, song) in _popular.indexed)
                        _TopSongTile(
                          song: song,
                          rank: index + 1,
                          focusNode: index == 0 ? _firstSongFocus : null,
                          onNavigateUp: index == 0 ? () => _actionsKey.currentState?.requestFocusOnFirst() : null,
                          onNavigateLeft: focus?.focusRail,
                          onPlay: _playTopSong,
                        ),
                    ],
                  ),
                ),
              ] else if (_topSongs.isNotEmpty) ...[
                const MusicSectionTitle(MusicStrings.topSongs),
                Padding(
                  padding: MusicPage.padding(context),
                  child: Column(
                    children: [
                      for (final (index, track) in _topSongs.indexed)
                        TrackRow(
                          item: track,
                          focusNode: index == 0 ? _firstSongFocus : null,
                          showTrackNumber: false,
                          isFirst: index == 0,
                          isLast: index == _topSongs.length - 1,
                          onNavigateUp: index == 0 ? () => _actionsKey.currentState?.requestFocusOnFirst() : null,
                          onTap: () => _playTopSong(track),
                        ),
                    ],
                  ),
                ),
              ],
              // Releases: the server's and the rest together, the rest with a request button.
              for (final kind in DiscographyGroupKind.values)
                if (_section(kind) case final items when items.isNotEmpty)
                  MusicFeedShelf(
                    title: _groupTitle(kind),
                    items: items,
                    onNavigateToSidebar: focus?.focusRail,
                  ),
              if ([..._similar.map(ServerFeedItem.new), ..._outsideSimilar] case final similar when similar.isNotEmpty)
                MusicFeedShelf(
                  title: MusicStrings.similarArtists,
                  items: similar,
                  onNavigateToSidebar: focus?.focusRail,
                ),
              if (summary != null && summary.isNotEmpty) ...[
                const MusicSectionTitle(MusicStrings.about),
                Padding(
                  padding: MusicPage.padding(context),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: CollapsibleText(
                      text: summary,
                      maxLines: 4,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ],
          SizedBox(height: 24 + MusicPage.bottomRoom(context)),
        ],
      ),
      ),
    );
  }
}

/// The artwork band at the top: the artist's wide art (or portrait) filling the width, fading
/// into the page, with the name in big type over the bottom edge.
class _ArtistHero extends StatelessWidget {
  const _ArtistHero({required this.artist, required this.client});

  final MediaItem artist;
  final MediaServerClient? client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTV = PlatformDetector.isTV();
    final size = MediaQuery.sizeOf(context);
    final wide = size.width > 700;
    final height = isTV ? size.height * 0.52 : (wide ? 380.0 : size.width * 0.95);
    final art = artist.artPath;
    final useArt = art != null && art.isNotEmpty && (wide || isTV);
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Sharp at the top, melting into the blurred colors behind the page.
          FadingArt(
            height: height,
            fadeFrom: 0.45,
            image: OptimizedMediaImage(
              client: client,
              imagePath: useArt ? art : artist.thumbPath,
              imageType: useArt ? ImageType.art : ImageType.square,
              width: size.width,
              height: height,
              fit: BoxFit.cover,
              alignment: useArt ? Alignment.center : const Alignment(0, -0.4),
              fallbackIcon: Symbols.artist_rounded,
            ),
          ),
          Positioned(
            left: MusicPage.padding(context).left,
            right: MusicPage.padding(context).right,
            bottom: 12,
            child: Text(
              artist.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: (isTV || wide ? theme.textTheme.displayMedium : theme.textTheme.displaySmall)?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                height: 1.05,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the artist's top songs: ours (play it) or from outside (preview it, request its album).
class _ArtistSong {
  const _ArtistSong(this.track, this.server);

  final ChartTrack track;
  final MediaItem? server;
}

class _TopSongTile extends StatelessWidget {
  const _TopSongTile({
    required this.song,
    required this.rank,
    required this.onPlay,
    this.focusNode,
    this.onNavigateUp,
    this.onNavigateLeft,
  });

  final _ArtistSong song;
  final int rank;
  final ValueChanged<MediaItem> onPlay;
  final FocusNode? focusNode;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateLeft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = song.track;
    final server = song.server;
    final MusicFeedItem item = server != null ? ServerFeedItem(server) : ExternalAlbumItem(track.album);
    final preview = track.previewUrl;

    void tap() {
      if (server != null) {
        onPlay(server);
      } else if (preview != null) {
        unawaited(MusicPreviewPlayer.instance.toggle(context, track.previewKey, [PreviewClip(title: track.title, url: preview)]));
      }
    }

    return FocusableWrapper(
      focusNode: focusNode,
      borderRadius: 12,
      onSelect: tap,
      onNavigateUp: onNavigateUp,
      onNavigateLeft: onNavigateLeft,
      onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(12),
        onTap: tap,
        onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
        onSecondaryTapUp: (details) => unawaited(MusicItemMenu.show(context, item, position: details.globalPosition)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              MusicArt(item: item, size: 48, radius: 8),
              SizedBox(
                width: 36,
                child: Text(
                  '$rank',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant),
                ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: MusicPreviewPlayer.instance,
                  builder: (context, _) {
                    final playing = server == null && MusicPreviewPlayer.instance.isPlaying(track.previewKey);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: playing ? scheme.primary : null,
                          ),
                        ),
                        if (playing)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 2, right: 12),
                            child: LinearProgressIndicator(
                              value: MusicPreviewPlayer.instance.loading ? null : MusicPreviewPlayer.instance.progress,
                              minHeight: 2,
                            ),
                          )
                        else
                          ArtistLinks(
                            credit: ArtistCredit([track.artistName], track.featuring),
                            suffix: server?.albumTitle ?? track.album.title,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    );
                  },
                ),
              ),
              // Not on the server: the request button says so.
              if (server == null) AlbumRequestIcon(album: track.album),
            ],
          ),
        ),
      ),
    );
  }
}
