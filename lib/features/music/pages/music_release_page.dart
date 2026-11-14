import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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
import '../../../widgets/app_icon.dart';
import '../../../widgets/music/track_row.dart';
import '../../../widgets/optimized_media_image.dart';
import '../discover/discover_feed.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import '../discover/music_previews.dart';
import '../music_strings.dart';
import '../widgets/art_backdrop.dart';
import '../widgets/music_item_menu.dart';
import '../widgets/music_page.dart';

/// Atlas: music mode's page for a release on the server: an album, an EP or a single. The cover
/// sits sharp at the top and melts into a blur of its own colors that tints the whole page;
/// then the title, Play / Shuffle / Love, the songs, the date and length, and more by the artist.
/// A single gets its own label and layout instead of looking like a one-song album.
class MusicReleasePage extends StatefulWidget {
  const MusicReleasePage({super.key, required this.album});

  final MediaItem album;

  @override
  State<MusicReleasePage> createState() => _MusicReleasePageState();
}

class _MusicReleasePageState extends State<MusicReleasePage> {
  MediaServerClient? _client;
  List<MediaItem>? _tracks;
  List<MusicFeedItem> _moreByArtist = const [];
  bool _failed = false;
  late bool _loved = widget.album.isFavorite ?? false;

  MediaItem get _album => widget.album;

  @override
  void initState() {
    super.initState();
    _client = context.tryGetMediaClientWithFallback(serverIdOrNull(_album.serverId));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) {
      setState(() => _failed = true);
      return;
    }
    try {
      final tracks = await client.fetchAlbumTracks(_album.id);
      if (!mounted) return;
      setState(() => _tracks = tracks);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
    final artistId = _album.parentId;
    if (artistId == null) return;
    try {
      final artist = await client.fetchItem(artistId);
      if (artist == null || artist.kind != MediaKind.artist) return;
      final groups = await client.fetchArtistDiscography(artist);
      if (!mounted) return;
      setState(() {
        _moreByArtist = [
          for (final group in groups)
            for (final item in group.items)
              if (item.id != _album.id) ServerFeedItem(item),
        ];
      });
    } catch (_) {
      // "More by" is a bonus; the page works without it.
    }
  }

  bool get _isSingle {
    final kind = classifyReleaseByShape(_album);
    final count = _tracks?.length ?? _album.childCount ?? _album.leafCount ?? 99;
    return kind == DiscographyGroupKind.singlesAndEps && count <= 3;
  }

  String get _kindLabel => switch (classifyReleaseByShape(_album)) {
    DiscographyGroupKind.singlesAndEps => _isSingle ? MusicStrings.singleLabel : MusicStrings.epLabel,
    DiscographyGroupKind.live => MusicStrings.live,
    DiscographyGroupKind.compilations => MusicStrings.compilationLabel,
    DiscographyGroupKind.albums => MusicStrings.albumLabel,
  };

  Future<void> _play({MediaItem? from, bool shuffle = false}) async {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    await MusicPreviewPlayer.instance.cancel();
    if (!mounted) return;
    await playTracks(
      context,
      tracks: tracks,
      startTrack: shuffle ? null : from,
      shuffle: shuffle,
      playContext: MusicPlayContext(title: _album.title ?? '', kind: MusicPlayContextKind.album),
    );
  }

  Future<void> _toggleLove() async {
    final client = _client;
    if (client == null) return;
    final next = !_loved;
    setState(() => _loved = next);
    try {
      await client.setFavorite(_album, next);
      MusicDiscovery.invalidate();
    } catch (_) {
      if (mounted) setState(() => _loved = !next);
    }
  }

  void _openArtist() {
    final client = _client;
    final id = _album.parentId;
    if (client == null || id == null) return;
    unawaited(openArtistById(context, client, id));
  }

  String _footer(List<MediaItem> tracks) {
    final totalMs = tracks.fold<int>(0, (sum, track) => sum + (track.durationMs ?? 0));
    final minutes = (totalMs / 60000).round();
    return [
      ?_album.originallyAvailableAt,
      MusicStrings.songCount(tracks.length),
      if (minutes > 0) MusicStrings.minutes(minutes),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 700;
    final isTV = PlatformDetector.isTV();
    final tracks = _tracks;
    final art = OptimizedMediaImage(
      client: _client,
      imagePath: _album.thumbPath,
      imageType: ImageType.square,
      fit: BoxFit.cover,
      fallbackIcon: Symbols.album_rounded,
    );
    final meta = [_kindLabel, if (_album.albumYear != null) '${_album.albumYear}'].join(' · ').toUpperCase();

    final titleBlock = Column(
      crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          meta,
          style: theme.textTheme.labelMedium?.copyWith(letterSpacing: 1.4, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          _album.title ?? '',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: (wide || isTV ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -1,
            height: 1.05,
          ),
        ),
        if (_album.albumArtistTitle case final artist? when artist.isNotEmpty)
          TextButton(
            onPressed: _openArtist,
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
            child: Text(
              artist,
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700),
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: wide ? WrapAlignment.start : WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              autofocus: isTV,
              onPressed: tracks == null || tracks.isEmpty ? null : () => unawaited(_play()),
              icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1.0),
              label: const Text(MusicStrings.play),
              style: FilledButton.styleFrom(minimumSize: const Size(130, 48)),
            ),
            if (!_isSingle)
              FilledButton.tonalIcon(
                onPressed: tracks == null || tracks.isEmpty ? null : () => unawaited(_play(shuffle: true)),
                icon: const AppIcon(Symbols.shuffle_rounded),
                label: const Text(MusicStrings.shuffle),
                style: FilledButton.styleFrom(minimumSize: const Size(130, 48)),
              ),
            IconButton.filledTonal(
              onPressed: () => unawaited(_toggleLove()),
              tooltip: _loved ? MusicStrings.unlove : MusicStrings.love,
              icon: AppIcon(Symbols.favorite_rounded, fill: _loved ? 1.0 : 0.0),
            ),
            IconButton.filledTonal(
              onPressed: () => unawaited(MusicItemMenu.show(context, ServerFeedItem(_album))),
              icon: const AppIcon(Symbols.more_horiz_rounded),
            ),
          ],
        ),
      ],
    );

    final header = wide
        ? Padding(
            padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 72, bottom: 12)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 300,
                  height: 300,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 18)),
                    ],
                  ),
                  child: art,
                ),
                const SizedBox(width: 32),
                Expanded(child: titleBlock),
              ],
            ),
          )
        : Column(
            children: [
              FadingArt(image: art, height: size.width, fadeFrom: 0.6),
              Transform.translate(
                offset: const Offset(0, -56),
                child: Padding(padding: MusicPage.padding(context), child: titleBlock),
              ),
            ],
          );

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: isTV
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
            ),
      body: ArtBackdrop(
        image: art,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            header,
            if (tracks == null && !_failed)
              const MusicPagePlaceholder()
            else if (_failed)
              const MusicPagePlaceholder(message: MusicStrings.loadFailed)
            else if (tracks != null) ...[
              Padding(
                padding: MusicPage.padding(context),
                child: Column(
                  children: [
                    for (final (index, track) in tracks.indexed)
                      TrackRow(
                        item: track,
                        isFirst: index == 0,
                        isLast: index == tracks.length - 1,
                        showTrackNumber: !_isSingle,
                        onTap: () => unawaited(_play(from: track)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 14)),
                child: Text(
                  _footer(tracks),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
            MusicFeedShelf(
              title: MusicStrings.moreBy(_album.albumArtistTitle ?? ''),
              items: _moreByArtist,
            ),
            SizedBox(height: 32 + MusicPage.bottomRoom(context)),
          ],
        ),
      ),
    );
  }
}
