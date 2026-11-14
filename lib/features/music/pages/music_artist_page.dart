import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_action_bar.dart';
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
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import '../widgets/music_shelves.dart';

/// Atlas: an Apple Music style artist page: full-bleed artwork fading into the page with the
/// name over it, Play / Shuffle / Station, the five songs played most, the discography split
/// into Albums, Singles & EPs, Live and Compilations, similar artists, then the bio.
class MusicArtistPage extends StatefulWidget {
  const MusicArtistPage({super.key, required this.artist});

  final MediaItem artist;

  @override
  State<MusicArtistPage> createState() => _MusicArtistPageState();
}

class _MusicArtistPageState extends State<MusicArtistPage> {
  final _actionsKey = GlobalKey<FocusableActionBarState>();
  final _shelvesKey = GlobalKey<MusicShelvesState>();
  final _firstSongFocus = FocusNode(debugLabel: 'music.artist.topSong');

  MediaServerClient? _client;
  List<MediaItem>? _allTracks;
  List<MediaItem> _topSongs = const [];
  List<ArtistDiscographyGroup> _discography = const [];
  List<MediaItem> _similar = const [];
  bool _failed = false;

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
  }

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
    unawaited(
      playTracks(
        context,
        tracks: _topSongs,
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

  IconData _groupIcon(DiscographyGroupKind kind) => switch (kind) {
    DiscographyGroupKind.albums => Symbols.album_rounded,
    DiscographyGroupKind.singlesAndEps => Symbols.music_note_rounded,
    DiscographyGroupKind.live => Symbols.mic_external_on_rounded,
    DiscographyGroupKind.compilations => Symbols.library_music_rounded,
  };

  void _focusBelowActions() {
    if (_topSongs.isNotEmpty) {
      _firstSongFocus.requestFocus();
    } else {
      _shelvesKey.currentState?.focusFirst();
    }
  }

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
      body: ListView(
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
              if (_topSongs.isNotEmpty) ...[
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
              MusicShelves(
                key: _shelvesKey,
                onNavigateUp: () {
                  if (_topSongs.isNotEmpty) {
                    _firstSongFocus.requestFocus();
                  } else {
                    _actionsKey.currentState?.requestFocusOnFirst();
                  }
                },
                onNavigateToSidebar: focus?.focusRail,
                shelves: [
                  for (final group in _discography)
                    MusicShelf(
                      id: 'artist-${group.kind.name}',
                      title: _groupTitle(group.kind),
                      icon: _groupIcon(group.kind),
                      items: group.items,
                    ),
                  MusicShelf(
                    id: 'artist-similar',
                    title: MusicStrings.similarArtists,
                    icon: Symbols.groups_rounded,
                    items: _similar,
                  ),
                ],
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
    final surface = theme.colorScheme.surface;

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          OptimizedMediaImage(
            client: client,
            imagePath: useArt ? art : artist.thumbPath,
            imageType: useArt ? ImageType.art : ImageType.square,
            width: size.width,
            height: height,
            fit: BoxFit.cover,
            alignment: useArt ? Alignment.center : const Alignment(0, -0.4),
            fallbackIcon: Symbols.artist_rounded,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.45, 1],
                colors: [Colors.black.withValues(alpha: 0.25), Colors.transparent, surface],
              ),
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
