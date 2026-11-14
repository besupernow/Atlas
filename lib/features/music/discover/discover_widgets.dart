import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
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
import '../../../widgets/optimized_media_image.dart';
import '../music_strings.dart';
import '../widgets/music_item_menu.dart';
import '../widgets/music_page.dart';
import 'allseerr_music.dart';
import 'deezer.dart';
import 'discover_models.dart';
import 'music_previews.dart';
import 'music_request_sheet.dart';

/// Open whatever a card stands for: the album or artist page for things on the server, the
/// request sheet for albums that aren't, the discovery sheet for artists that aren't.
Future<void> openFeedItem(BuildContext context, MusicFeedItem item) async {
  switch (item) {
    case ServerFeedItem(:final item):
      await MusicPreviewPlayer.instance.cancel();
      if (!context.mounted) return;
      switch (item.kind) {
        case MediaKind.artist:
          await navigateToArtist(context, item);
        case MediaKind.track:
          // A song opens its release (album or single), it doesn't just start playing.
          await openTrackRelease(context, item);
        default:
          await navigateToAlbum(context, item);
      }
    case ExternalAlbumItem(:final album):
      await showAlbumRequestSheet(context, album);
    case ExternalArtistItem(:final artist):
      await showArtistDiscoverySheet(context, artist);
  }
}

/// Open the album (or single) a server song is on.
Future<void> openTrackRelease(BuildContext context, MediaItem track) async {
  final albumId = track.parentId;
  final client = context.tryGetMediaClientWithFallback(serverIdOrNull(track.serverId));
  if (albumId == null || client == null) {
    await playTrackWithAlbumContext(context, track);
    return;
  }
  final album = await client.fetchItem(albumId).catchError((Object _) => null);
  if (!context.mounted) return;
  if (album == null) {
    await playTrackWithAlbumContext(context, track);
    return;
  }
  await navigateToAlbum(context, album);
}

/// Play a server album straight away (hero cards).
Future<void> playServerAlbum(BuildContext context, MediaItem album, {bool shuffle = false}) async {
  await MusicPreviewPlayer.instance.cancel();
  if (!context.mounted) return;
  final client = context.tryGetMediaClientWithFallback(serverIdOrNull(album.serverId));
  if (client == null) return;
  await playFetchedTracks(
    context,
    fetch: () => client.fetchPlayableDescendants(album.id),
    playContext: MusicPlayContext(title: album.title ?? '', kind: MusicPlayContextKind.album),
    shuffle: shuffle,
  );
}

/// Square (or round, for artists) artwork from the server or from the web, with a soft shadow.
class MusicArt extends StatelessWidget {
  const MusicArt({super.key, required this.item, required this.size, this.radius = 14, this.shadow = true});

  final MusicFeedItem item;
  final double size;
  final double radius;
  final bool shadow;

  bool get _round => switch (item) {
    ServerFeedItem(:final item) => item.kind == MediaKind.artist,
    ExternalArtistItem() => true,
    ExternalAlbumItem() => false,
  };

  @override
  Widget build(BuildContext context) {
    final MediaServerClient? client;
    final String? path;
    IconData fallback = Symbols.album_rounded;
    switch (item) {
      case ServerFeedItem(:final item):
        client = context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId));
        path = item.kind == MediaKind.track ? (item.parentThumbPath ?? item.thumbPath) : item.thumbPath;
        if (item.kind == MediaKind.artist) fallback = Symbols.artist_rounded;
      case ExternalAlbumItem(:final album):
        client = null;
        path = album.coverUrl;
      case ExternalArtistItem(:final artist):
        client = null;
        path = artist.imageUrl;
        fallback = Symbols.artist_rounded;
    }
    final shape = _round ? BorderRadius.circular(size) : BorderRadius.circular(radius);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: shape,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        // A hairline edge so dark covers don't melt into a dark page.
        border: shadow ? Border.all(color: Colors.white.withValues(alpha: 0.07)) : null,
        boxShadow: shadow
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 18, offset: const Offset(0, 8))]
            : null,
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: OptimizedMediaImage(
          client: client,
          imagePath: path,
          imageType: ImageType.square,
          width: size,
          height: size,
          fit: BoxFit.cover,
          fallbackIcon: fallback,
        ),
      ),
    );
  }
}

/// A frosted round button laid over artwork.
class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, this.onTap, this.size = 34, this.progress, this.busy = false});

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double? progress;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: Colors.black.withValues(alpha: 0.38),
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (busy || progress != null)
                    SizedBox(
                      width: size - 4,
                      height: size - 4,
                      child: CircularProgressIndicator(
                        value: busy ? null : progress,
                        strokeWidth: 2,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                  AppIcon(icon, size: size * 0.55, color: Colors.white, fill: 1.0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The marker on albums that aren't on the server (and their request state).
class NotOnServerBadge extends StatelessWidget {
  const NotOnServerBadge({super.key, required this.status, this.mbid, this.size = 26});

  final DiscoverStatus status;

  /// The album's id, so the badge follows a request made anywhere in the app.
  final String? mbid;
  final double size;

  @override
  Widget build(BuildContext context) {
    final id = mbid;
    if (id == null) return _badge(status);
    return ListenableBuilder(
      listenable: StatusOverrides.instance,
      builder: (context, _) => _badge(StatusOverrides.instance.statusOf(id) ?? status),
    );
  }

  Widget _badge(DiscoverStatus status) {
    final icon = switch (status) {
      DiscoverStatus.requested => Symbols.schedule_rounded,
      DiscoverStatus.downloading => Symbols.downloading_rounded,
      DiscoverStatus.partial || DiscoverStatus.available => Symbols.check_circle_rounded,
      DiscoverStatus.notRequested => Symbols.cloud_rounded,
    };
    final label = switch (status) {
      DiscoverStatus.requested => MusicStrings.requested,
      DiscoverStatus.downloading => MusicStrings.downloading,
      DiscoverStatus.partial || DiscoverStatus.available => MusicStrings.onServer,
      DiscoverStatus.notRequested => MusicStrings.notOnServer,
    };
    return Tooltip(
      message: label,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: size,
            height: size,
            color: Colors.black.withValues(alpha: 0.42),
            alignment: Alignment.center,
            child: AppIcon(icon, size: size * 0.6, color: Colors.white, fill: 1.0),
          ),
        ),
      ),
    );
  }
}

/// The preview button for an album that isn't on the server: tap to hear it, tap to stop.
class AlbumPreviewButton extends StatelessWidget {
  const AlbumPreviewButton({super.key, required this.album, this.size = 34});

  final DiscoverAlbum album;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!MusicPreviews.supported) return const SizedBox.shrink();
    final player = MusicPreviewPlayer.instance;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final playing = player.playingKey == album.mbid;
        return _GlassButton(
          icon: playing ? Symbols.stop_rounded : Symbols.play_arrow_rounded,
          size: size,
          busy: playing && player.loading,
          progress: playing && !player.loading ? player.progress : null,
          onTap: () => unawaited(previewAlbum(context, album)),
        );
      },
    );
  }
}

/// Start (or stop) [album]'s previews; says so when there aren't any.
Future<void> previewAlbum(BuildContext context, DiscoverAlbum album) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final clips = album.deezerId == null
      ? MusicPreviews.forAlbum(album.artistName, album.title)
      : quietly(
          Deezer.details(album).then(
            (details) => [
              for (final track in details?.tracks ?? const <DiscoverTrack>[])
                if (track.previewUrl case final url?)
                  PreviewClip(title: track.title, url: url, number: int.tryParse(track.number)),
            ],
          ),
          const <PreviewClip>[],
          'Deezer previews',
        );
  await MusicPreviewPlayer.instance.playAlbum(context, album.mbid, clips);
  if ((await clips).isEmpty) {
    messenger?.showSnackBar(const SnackBar(content: Text(MusicStrings.noPreview)));
  }
}

/// One card: big artwork, a title and a line under it. Albums that aren't on the server carry
/// the badge and a preview button.
class MusicFeedCard extends StatelessWidget {
  const MusicFeedCard({
    super.key,
    required this.item,
    required this.size,
    this.focusNode,
    this.onNavigateLeft,
    this.onFocusChange,
    this.onTap,
  });

  final MusicFeedItem item;
  final double size;
  final FocusNode? focusNode;
  final VoidCallback? onNavigateLeft;
  final ValueChanged<bool>? onFocusChange;

  /// Replaces the default (open the album, artist or request sheet).
  final ValueChanged<MusicFeedItem>? onTap;

  (String, String?) get _lines => switch (item) {
    ServerFeedItem(:final item, :final reason) => (
      item.title ?? '',
      reason ??
          switch (item.kind) {
            MediaKind.album => [item.albumArtistTitle, item.albumYear?.toString()].whereType<String>().join(' · '),
            MediaKind.track => item.trackArtistTitle,
            _ => null,
          },
    ),
    ExternalAlbumItem(:final album) => (
      album.title,
      album.reason ?? [album.artistName, album.year].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
    ),
    ExternalArtistItem(:final artist) => (artist.name, artist.reason),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, subtitle) = _lines;
    final external = item is ExternalAlbumItem ? (item as ExternalAlbumItem).album : null;
    final round = item is ExternalArtistItem || (item is ServerFeedItem && (item as ServerFeedItem).item.kind == MediaKind.artist);
    void open() {
      final override = onTap;
      if (override != null) {
        override(item);
      } else {
        unawaited(openFeedItem(context, item));
      }
    }


    return SizedBox(
      width: size,
      child: FocusableWrapper(
        focusNode: focusNode,
        borderRadius: round ? size : 16,
        onSelect: open,
        onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
        onNavigateLeft: onNavigateLeft,
        onFocusChange: onFocusChange,
        semanticLabel: [title, subtitle].whereType<String>().join(', '),
        child: InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(16),
          onTap: open,
          onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
          onSecondaryTapUp: (details) => unawaited(MusicItemMenu.show(context, item, position: details.globalPosition)),
          child: Column(
            crossAxisAlignment: round ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  MusicArt(item: item, size: size),
                  if (external != null) ...[
                    Positioned(top: 8, right: 8, child: NotOnServerBadge(status: external.status, mbid: external.mbid)),
                    Positioned(left: 8, bottom: 8, child: AlbumPreviewButton(album: external)),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: round ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subtitle != null && subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: round ? TextAlign.center : TextAlign.start,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled horizontal row of cards.
class MusicFeedShelf extends StatelessWidget {
  const MusicFeedShelf({
    super.key,
    required this.title,
    required this.items,
    this.subtitle,
    this.large = false,
    this.onNavigateToSidebar,
    this.onItemTap,
    this.onSeeAll,
    this.kicker,
    this.ranked = false,
  });

  final String title;
  final String? subtitle;
  final List<MusicFeedItem> items;
  final bool large;
  final String? kicker;

  /// Chart order: big outlined numbers beside each card.
  final bool ranked;
  final VoidCallback? onNavigateToSidebar;
  final ValueChanged<MusicFeedItem>? onItemTap;

  /// Makes the title tappable with a ">" (Apple's "see all").
  final VoidCallback? onSeeAll;

  static double cardSize(BuildContext context, {bool large = false}) {
    final isTV = PlatformDetector.isTV();
    final width = MediaQuery.sizeOf(context).width;
    final base = isTV ? 190.0 : (width >= 900 ? 176.0 : 150.0);
    return large ? base * 1.25 : base;
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final size = cardSize(context, large: large);
    final padding = MusicPage.padding(context);
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: padding,
            child: MusicSectionHeader(kicker: kicker, title: title, subtitle: subtitle, onSeeAll: onSeeAll),
          ),
          const SizedBox(height: 12),
          SizedBox(
            // Art, two lines of text and the focus ring's room.
            height: size + 62,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: padding.add(const EdgeInsets.only(bottom: 4)),
              clipBehavior: Clip.none,
              itemCount: items.length,
              separatorBuilder: (_, _) => SizedBox(width: large ? 18 : 14),
              itemBuilder: (context, index) {
                final card = MusicFeedCard(
                  key: ValueKey(items[index].key),
                  item: items[index],
                  size: size,
                  onNavigateLeft: index == 0 ? onNavigateToSidebar : null,
                  onTap: onItemTap,
                );
                if (!ranked) return card;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _RankNumber(rank: index + 1, height: size),
                    card,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Atlas: a section's heading, magazine style: a small accent-colored word on top ("FOR
/// YOU", "CHARTS"), the title big and tight, an optional line under it, and with [onSeeAll] a
/// tappable ">" (Apple's "see all").
class MusicSectionHeader extends StatelessWidget {
  const MusicSectionHeader({super.key, required this.title, this.kicker, this.subtitle, this.onSeeAll});

  final String title;
  final String? kicker;
  final String? subtitle;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4, height: 1.1),
    );
    final seeAll = onSeeAll;
    final titleRow = seeAll == null
        ? titleText
        : FocusableWrapper(
            borderRadius: 8,
            onSelect: seeAll,
            child: InkWell(
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(8),
              onTap: seeAll,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: titleText),
                  const SizedBox(width: 2),
                  AppIcon(Symbols.chevron_right_rounded, color: scheme.onSurfaceVariant, size: 26),
                ],
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (kicker case final word?)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  word,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  ),
                ),
              ],
            ),
          ),
        titleRow,
        if (subtitle case final line?)
          Text(line, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

/// A chart position drawn as a big outlined numeral beside the card.
class _RankNumber extends StatelessWidget {
  const _RankNumber({required this.rank, required this.height});

  final int rank;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = height * 0.62;
    final style = TextStyle(fontSize: size, height: 1, fontWeight: FontWeight.w900, letterSpacing: -size * 0.08);
    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Stack(
            children: [
              Text(
                '$rank',
                style: style.copyWith(
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 2.5
                    ..color = scheme.primary,
                ),
              ),
              Text('$rank', style: style.copyWith(color: scheme.primary.withValues(alpha: 0.12))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Atlas: the big swipeable banner at the top of Home and New: the artwork blurred into the
/// background, the cover, and Play (or Preview and Request) right there.
class MusicHeroCarousel extends StatefulWidget {
  const MusicHeroCarousel({super.key, required this.items, required this.eyebrow, this.onNavigateToSidebar});

  final List<MusicFeedItem> items;
  final String eyebrow;
  final VoidCallback? onNavigateToSidebar;

  @override
  State<MusicHeroCarousel> createState() => _MusicHeroCarouselState();
}

class _MusicHeroCarouselState extends State<MusicHeroCarousel> {
  PageController? _controller;
  double? _fraction;
  Timer? _auto;
  int _page = 0;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _auto = Timer.periodic(const Duration(seconds: 8), (_) {
      final controller = _controller;
      if (!mounted || _focused || controller == null || !controller.hasClients || widget.items.length < 2) return;
      unawaited(
        controller.animateToPage(
          (_page + 1) % widget.items.length,
          duration: const Duration(milliseconds: 650),
          curve: Curves.easeInOutCubic,
        ),
      );
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final target = _page + delta;
    if (target < 0 || target >= widget.items.length) return;
    unawaited(
      _controller?.animateToPage(target, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final width = MediaQuery.sizeOf(context).width;
    final isTV = PlatformDetector.isTV();
    final wide = width >= 700;
    final fraction = wide ? (isTV ? 0.82 : 0.86) : 0.92;
    if (_fraction != fraction) {
      final old = _controller;
      _controller = PageController(viewportFraction: fraction, initialPage: _page);
      _fraction = fraction;
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    final height = isTV ? 340.0 : (wide ? 320.0 : 420.0);

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: [
          SizedBox(
            height: height,
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.items.length,
              onPageChanged: (page) => setState(() => _page = page),
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: FocusableWrapper(
                  borderRadius: 28,
                  autoScroll: true,
                  onSelect: () => unawaited(openFeedItem(context, widget.items[index])),
                  onNavigateLeft: () {
                    if (index == 0) {
                      widget.onNavigateToSidebar?.call();
                    } else {
                      _go(-1);
                    }
                  },
                  onNavigateRight: () => _go(1),
                  onFocusChange: (focused) {
                    _focused = focused;
                    if (focused && index != _page) _go(index - _page);
                  },
                  child: _HeroCard(item: widget.items[index], eyebrow: widget.eyebrow, wide: wide),
                ),
              ),
            ),
          ),
          if (widget.items.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _page ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.item, required this.eyebrow, required this.wide});

  final MusicFeedItem item;
  final String eyebrow;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (String title, String subtitle, String? reason) = switch (item) {
      ServerFeedItem(:final item, :final reason) => (item.title ?? '', item.albumArtistTitle ?? '', reason),
      ExternalAlbumItem(:final album) => (album.title, album.artistName, album.reason),
      ExternalArtistItem(:final artist) => (artist.name, '', artist.reason),
    };
    final external = item is ExternalAlbumItem ? (item as ExternalAlbumItem).album : null;
    final server = item is ServerFeedItem ? (item as ServerFeedItem).item : null;
    final kind = external?.type ?? (server != null ? MusicStrings.onServer : null);

    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (server != null) ...[
          FilledButton.icon(
            onPressed: () => unawaited(playServerAlbum(context, server)),
            icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1.0),
            label: const Text(MusicStrings.play),
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
          ),
          IconButton.filledTonal(
            onPressed: () => unawaited(playServerAlbum(context, server, shuffle: true)),
            icon: const AppIcon(Symbols.shuffle_rounded),
            tooltip: MusicStrings.shuffle,
          ),
        ],
        if (external != null) ...[
          if (MusicPreviews.supported)
            ListenableBuilder(
              listenable: MusicPreviewPlayer.instance,
              builder: (context, _) {
                final playing = MusicPreviewPlayer.instance.playingKey == external.mbid;
                return FilledButton.icon(
                  onPressed: () => unawaited(previewAlbum(context, external)),
                  icon: AppIcon(playing ? Symbols.stop_rounded : Symbols.play_arrow_rounded, fill: 1.0),
                  label: Text(playing ? MusicStrings.stop : MusicStrings.preview),
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                );
              },
            ),
          RequestButton(album: external, compact: true),
        ],
      ],
    );

    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                (reason ?? eyebrow).toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.75),
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (kind != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white54),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  kind.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (wide ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            letterSpacing: -1,
            height: 1.0,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
          ),
        ],
        const SizedBox(height: 14),
        buttons,
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: Material(
        color: Colors.black,
        child: InkWell(
          canRequestFocus: false,
          onTap: () => unawaited(openFeedItem(context, item)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final artSize = constraints.maxHeight - 48;
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Phones: the cover is the poster. Wide: the cover, blown up and blurred,
                  // with the sharp cover on the right.
                  if (wide)
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.decal),
                      child: Transform.scale(scale: 1.5, child: MusicArt(item: item, size: 600, radius: 0, shadow: false)),
                    )
                  else
                    MusicArt(item: item, size: constraints.maxWidth, radius: 0, shadow: false),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: wide ? Alignment.centerLeft : Alignment.topCenter,
                        end: wide ? Alignment.centerRight : Alignment.bottomCenter,
                        stops: wide ? const [0, 0.7] : const [0.35, 1],
                        colors: [
                          Colors.black.withValues(alpha: wide ? 0.7 : 0),
                          Colors.black.withValues(alpha: wide ? 0.15 : 0.88),
                        ],
                      ),
                    ),
                  ),
                  if (wide)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Row(
                        children: [
                          Expanded(child: Align(alignment: Alignment.centerLeft, child: text)),
                          const SizedBox(width: 24),
                          Stack(
                            children: [
                              MusicArt(item: item, size: artSize, radius: 20),
                              if (external != null)
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: NotOnServerBadge(status: external.status, mbid: external.mbid, size: 30),
                                ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else ...[
                    if (external != null)
                      Positioned(
                        top: 14,
                        right: 14,
                        child: NotOnServerBadge(status: external.status, mbid: external.mbid, size: 30),
                      ),
                    Positioned(left: 20, right: 20, bottom: 20, child: text),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Ask Allseerr for [album] (an album, EP or single). False when it couldn't (not connected,
/// no MusicBrainz match, server error).
Future<bool> requestAlbum(BuildContext context, DiscoverAlbum album) async {
  final seerr = AllseerrMusic.of(context);
  if (seerr == null) return false;
  try {
    await seerr.request(album);
    return true;
  } catch (_) {
    return false;
  }
}

/// Request [album]: one tap, then it shows where it stands (requested, downloading, here).
class RequestButton extends StatefulWidget {
  const RequestButton({super.key, required this.album, this.compact = false, this.onOpenServerCopy});

  final DiscoverAlbum album;
  final bool compact;

  /// Shown as "Open" once the album is on the server.
  final VoidCallback? onOpenServerCopy;

  @override
  State<RequestButton> createState() => _RequestButtonState();
}

class _RequestButtonState extends State<RequestButton> {
  bool _busy = false;

  DiscoverStatus get _status => StatusOverrides.instance.statusOf(widget.album.mbid) ?? widget.album.status;

  Future<void> _request() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final seerr = AllseerrMusic.of(context);
    if (seerr == null) {
      messenger?.showSnackBar(const SnackBar(content: Text(MusicStrings.requestUnavailable)));
      return;
    }
    setState(() => _busy = true);
    try {
      await seerr.request(widget.album);
      messenger?.showSnackBar(const SnackBar(content: Text(MusicStrings.requestSent)));
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text(MusicStrings.requestFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: StatusOverrides.instance,
      builder: (context, _) {
        final status = _status;
        final scheme = Theme.of(context).colorScheme;
        if (_busy) {
          return FilledButton.icon(
            onPressed: null,
            icon: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            label: const Text(MusicStrings.requesting),
          );
        }
        if (status.onServer) {
          return FilledButton.tonalIcon(
            onPressed: widget.onOpenServerCopy,
            icon: const AppIcon(Symbols.check_rounded),
            label: Text(widget.onOpenServerCopy != null ? MusicStrings.open : MusicStrings.onServer),
          );
        }
        if (status.inProgress) {
          return FilledButton.tonalIcon(
            onPressed: null,
            icon: AppIcon(status == DiscoverStatus.downloading ? Symbols.downloading_rounded : Symbols.schedule_rounded),
            label: Text(status == DiscoverStatus.downloading ? MusicStrings.downloading : MusicStrings.requested),
          );
        }
        return FilledButton.icon(
          onPressed: () => unawaited(_request()),
          style: FilledButton.styleFrom(backgroundColor: scheme.primary, foregroundColor: scheme.onPrimary),
          icon: const AppIcon(Symbols.add_rounded),
          label: const Text(MusicStrings.request),
        );
      },
    );
  }
}
