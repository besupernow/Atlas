import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../media/media_item.dart';
import '../../../utils/media_image_helper.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/optimized_media_image.dart';
import '../music_strings.dart';
import '../widgets/art_backdrop.dart';
import '../widgets/music_page.dart';
import '../widgets/release_hero.dart';
import 'allseerr_music.dart';
import 'deezer.dart';
import 'discover_feed.dart';
import 'discover_models.dart';
import 'discover_widgets.dart';
import 'music_previews.dart';
import 'music_resolver.dart';

/// Phones get a tall sheet; tablets, desktop and TV a full-screen page.
Future<void> _present(BuildContext context, Widget Function(BuildContext host) builder) async {
  final host = context;
  if (PlatformDetector.isTV() || MediaQuery.sizeOf(context).width >= 700) {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => builder(host),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.04), end: Offset.zero)
                .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.94,
      child: ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(28)), child: builder(host)),
    ),
  );
}

/// Atlas: an album that isn't on the server: the cover, what it is, a preview of every song,
/// and one big Request button.
Future<void> showAlbumRequestSheet(BuildContext context, DiscoverAlbum album) =>
    _present(context, (host) => _AlbumRequestView(album: album, host: host));

/// Atlas: an artist that isn't on the server: who they are, their albums (each requestable),
/// and artists like them.
Future<void> showArtistDiscoverySheet(BuildContext context, DiscoverArtist artist) =>
    _present(context, (host) => _ArtistDiscoveryView(artist: artist, host: host));

/// The blurred-artwork backdrop both views sit on.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.imageUrl, required this.child});

  final String? imageUrl;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ArtBackdrop(
        image: url == null
            ? null
            : OptimizedMediaImage(client: null, imagePath: url, imageType: ImageType.square, fit: BoxFit.cover),
        child: child,
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: IconButton.filledTonal(
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const AppIcon(Symbols.close_rounded),
        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      ),
    ),
  );
}

class _AlbumRequestView extends StatefulWidget {
  const _AlbumRequestView({required this.album, required this.host});

  final DiscoverAlbum album;
  final BuildContext host;

  @override
  State<_AlbumRequestView> createState() => _AlbumRequestViewState();
}

class _AlbumRequestViewState extends State<_AlbumRequestView> {
  DiscoverAlbumDetails? _details;
  MediaItem? _serverCopy;
  late Future<List<PreviewClip>> _clips;

  DiscoverAlbum get _album => _details?.album ?? widget.album;

  @override
  void initState() {
    super.initState();
    _clips = MusicPreviews.forAlbum(widget.album.artistName, widget.album.title);
    unawaited(_load());
  }

  @override
  void dispose() {
    if (MusicPreviewPlayer.instance.playingKey == widget.album.mbid) unawaited(MusicPreviewPlayer.instance.stop());
    super.dispose();
  }

  /// Deezer for the art, track list and previews (its metadata is the best we can reach);
  /// Allseerr for whether we have it or asked for it (and the MusicBrainz id requests need).
  Future<void> _load() async {
    final seerr = AllseerrMusic.of(context);
    final discovery = MusicDiscovery.of(context);
    final album = widget.album;
    final results = await Future.wait<Object?>([
      quietly(Deezer.details(album), null, 'Deezer album'),
      if (seerr == null)
        Future.value()
      else
        // Its release group (from its codes, for albums from Deezer or Last.fm), then what
        // Allseerr knows about it.
        quietly(
          () async {
            final found = await MusicResolver.releaseGroup(album);
            return found == null ? null : await seerr.album(found);
          }(),
          null,
          'album details',
        ),
      quietly(discovery.serverCopy(album), null, 'server copy'),
    ]);
    if (!mounted) return;
    final deezer = results[0] as DeezerAlbumDetails?;
    final fromSeerr = results[1];
    final seerrDetails = fromSeerr is DiscoverAlbumDetails ? fromSeerr : null;
    final matched = fromSeerr is DiscoverAlbum ? fromSeerr : seerrDetails?.album;
    final merged = (matched ?? album).copyWith(
      coverUrl: deezer?.album.coverUrl ?? album.coverUrl,
      deezerId: deezer?.album.deezerId ?? album.deezerId,
    );
    final tracks = (deezer?.tracks.isNotEmpty ?? false) ? deezer!.tracks : (seerrDetails?.tracks ?? const <DiscoverTrack>[]);
    final previews = [
      for (final track in tracks)
        if (track.previewUrl case final url?) PreviewClip(title: track.title, url: url, number: int.tryParse(track.number)),
    ];
    setState(() {
      _details = DiscoverAlbumDetails(
        album: merged,
        tracks: tracks,
        genres: (deezer?.genres.isNotEmpty ?? false) ? deezer!.genres : (seerrDetails?.genres ?? const []),
        about: seerrDetails?.about,
        artistImageUrl: seerrDetails?.artistImageUrl,
      );
      _serverCopy = results[2] as MediaItem?;
      if (previews.isNotEmpty) _clips = Future.value(previews);
    });
  }

  void _openServerCopy() {
    final copy = _serverCopy;
    if (copy == null) return;
    Navigator.of(context).pop();
    if (widget.host.mounted) unawaited(navigateToAlbum(widget.host, copy));
  }

  /// The clip for a track: same number, else same title.
  int? _clipIndex(List<PreviewClip> clips, DiscoverTrack track, int position) {
    final number = int.tryParse(track.number);
    final byNumber = clips.indexWhere((clip) => clip.number != null && clip.number == number);
    if (byNumber >= 0 && track.disc <= 1) return byNumber;
    final title = track.title.toLowerCase();
    final byTitle = clips.indexWhere((clip) => clip.title.toLowerCase() == title);
    if (byTitle >= 0) return byTitle;
    return position < clips.length ? position : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final album = _album;
    final details = _details;
    final hero = ReleaseHero(
      art: OptimizedMediaImage(
        client: null,
        imagePath: album.coverUrl,
        imageType: ImageType.square,
        fit: BoxFit.cover,
        fallbackIcon: Symbols.album_rounded,
      ),
      eyebrow: [album.type ?? MusicStrings.albumLabel, ?album.year].join(' · '),
      title: album.title,
      credit: album.credit,
      details: [
        ...?details?.genres.take(2),
        if (details != null && details.tracks.isNotEmpty) MusicStrings.songCount(details.tracks.length),
      ].join(' · '),
      badge: NotOnServerBadge(status: album.status, mbid: album.mbid, size: 32),
      actions: [
        if (MusicPreviews.supported)
          ListenableBuilder(
            listenable: MusicPreviewPlayer.instance,
            builder: (context, _) {
              final playing = MusicPreviewPlayer.instance.playingKey == album.mbid;
              return FilledButton.tonalIcon(
                autofocus: PlatformDetector.isTV(),
                onPressed: () => unawaited(previewAlbum(context, album)),
                icon: AppIcon(playing ? Symbols.stop_rounded : Symbols.play_arrow_rounded, fill: 1.0),
                label: Text(playing ? MusicStrings.stop : MusicStrings.preview),
                style: ReleaseButtons.secondary,
              );
            },
          ),
        RequestButton(album: album, onOpenServerCopy: _serverCopy == null ? null : _openServerCopy),
      ],
    );

    return _Backdrop(
      imageUrl: album.coverUrl,
      child: Stack(
        children: [
          ListView(
            // Room at the bottom so the mini player never covers the last songs.
            padding: EdgeInsets.only(bottom: 40 + MusicPage.bottomRoom(context)),
            children: [
              hero,
              Padding(
                padding: MusicPage.padding(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              if (details == null)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (details.tracks.isNotEmpty) ...[
                Text(MusicStrings.tracks, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                FutureBuilder<List<PreviewClip>>(
                  future: _clips,
                  builder: (context, snapshot) {
                    final clips = snapshot.data ?? const <PreviewClip>[];
                    return Column(
                      children: [
                        for (final (index, track) in details.tracks.indexed)
                          _TrackPreviewRow(
                            track: track,
                            albumArtist: album.artistName,
                            albumKey: album.mbid,
                            clips: clips,
                            clipIndex: clips.isEmpty ? null : _clipIndex(clips, track, index),
                          ),
                      ],
                    );
                  },
                ),
              ],
              if (details?.about case final about? when about.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(album.artistName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  about,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.45),
                ),
              ],
                  ],
                ),
              ),
            ],
          ),
          const _CloseButton(),
        ],
      ),
    );
  }
}

class _TrackPreviewRow extends StatelessWidget {
  const _TrackPreviewRow({
    required this.track,
    required this.albumArtist,
    required this.albumKey,
    required this.clips,
    required this.clipIndex,
  });

  final DiscoverTrack track;

  /// Songs credited to someone else (or with features) show their own artists.
  final String albumArtist;
  final String albumKey;
  final List<PreviewClip> clips;
  final int? clipIndex;

  static String _length(Duration? length) {
    if (length == null) return '';
    final minutes = length.inMinutes;
    final seconds = (length.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = clipIndex;
    final canPreview = MusicPreviews.supported && index != null;
    void toggle() {
      if (index != null) unawaited(MusicPreviewPlayer.instance.toggle(context, albumKey, clips, startAt: index));
    }

    return ListenableBuilder(
      listenable: MusicPreviewPlayer.instance,
      builder: (context, _) {
        final player = MusicPreviewPlayer.instance;
        final playing = index != null && player.isPlaying(albumKey, index: index);
        return FocusableWrapper(
          borderRadius: 12,
          onSelect: canPreview ? toggle : null,
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(12),
            onTap: canPreview ? toggle : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: playing
                        ? AppIcon(Symbols.graphic_eq_rounded, color: theme.colorScheme.primary)
                        : Text(
                            track.number,
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: playing ? theme.colorScheme.primary : null,
                            fontWeight: playing ? FontWeight.w600 : null,
                          ),
                        ),
                        if (!playing && track.artist != null && track.artist != albumArtist)
                          ArtistLinks(
                            credit: ArtistCredit.parse(track.artist!, title: track.title),
                            accent: true,
                            style: theme.textTheme.bodySmall,
                          ),
                        if (playing)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, right: 12),
                            child: LinearProgressIndicator(
                              value: player.loading ? null : player.progress,
                              minHeight: 2,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    _length(track.length),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (canPreview) ...[
                    const SizedBox(width: 8),
                    AppIcon(
                      playing ? Symbols.stop_circle_rounded : Symbols.play_circle_rounded,
                      color: theme.colorScheme.primary,
                      fill: 1.0,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArtistDiscoveryView extends StatefulWidget {
  const _ArtistDiscoveryView({required this.artist, required this.host});

  final DiscoverArtist artist;
  final BuildContext host;

  @override
  State<_ArtistDiscoveryView> createState() => _ArtistDiscoveryViewState();
}

class _ArtistDiscoveryViewState extends State<_ArtistDiscoveryView> {
  List<MusicFeedItem>? _albums;
  List<MusicFeedItem>? _singles;
  List<MusicFeedItem> _similar = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final discovery = MusicDiscovery.of(context);
    final results = await Future.wait([
      quietly(discovery.discographyOf(widget.artist), const <MusicFeedItem>[], 'discography'),
      quietly(discovery.similarTo(widget.artist), const <MusicFeedItem>[], 'similar artists'),
    ]);
    if (!mounted) return;
    final all = results[0];
    bool isSingle(MusicFeedItem item) =>
        item is ExternalAlbumItem && (item.album.type ?? '').toLowerCase() == 'single';
    setState(() {
      _albums = [for (final item in all) if (!isSingle(item)) item];
      _singles = [for (final item in all) if (isSingle(item)) item];
      _similar = results[1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artist = widget.artist;
    final albums = _albums;
    final size = MediaQuery.sizeOf(context);
    return _Backdrop(
      imageUrl: artist.backdropUrl ?? artist.imageUrl,
      child: Stack(
        children: [
          ListView(
            padding: EdgeInsets.only(bottom: 40 + MusicPage.bottomRoom(context)),
            children: [
              SizedBox(
                height: size.width >= 700 ? 320 : 300,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (artist.backdropUrl ?? artist.imageUrl case final image?)
                      ShaderMask(
                        shaderCallback: (rect) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.white, Colors.transparent],
                          stops: [0.5, 1],
                        ).createShader(rect),
                        blendMode: BlendMode.dstIn,
                        child: OptimizedMediaImage(
                          client: null,
                          imagePath: image,
                          imageType: ImageType.art,
                          fit: BoxFit.cover,
                          alignment: const Alignment(0, -0.3),
                        ),
                      ),
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: 12,
                      child: Text(
                        artist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
                      ),
                    ),
                  ],
                ),
              ),
              if (albums == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else ...[
                MusicFeedShelf(title: MusicStrings.albumsAndEps, items: albums),
                MusicFeedShelf(title: MusicStrings.singles, items: _singles ?? const []),
                MusicFeedShelf(title: MusicStrings.similarArtists, items: _similar),
                if (albums.isEmpty && (_singles ?? const []).isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text(MusicStrings.loadFailed)),
                  ),
              ],
            ],
          ),
          const _CloseButton(),
        ],
      ),
    );
  }
}
