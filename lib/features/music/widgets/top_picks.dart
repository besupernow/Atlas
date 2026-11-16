import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../media/ids.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/provider_extensions.dart';
import '../../../widgets/app_icon.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import '../discover/music_mixes.dart';
import '../discover/music_previews.dart';
import '../music_strings.dart';
import 'music_item_menu.dart';
import 'music_page.dart';

/// One card in Top Picks for You, with the small label above it ("Made for You",
/// "Listen Again", "Featuring Phoebe Bridgers", "Recommended").
sealed class TopPick {
  const TopPick(this.eyebrow);

  final String eyebrow;
}

final class MixPick extends TopPick {
  const MixPick(this.mix) : super(MusicStrings.madeForYou);

  final MusicMix mix;
}

final class ItemPick extends TopPick {
  const ItemPick(this.item, super.eyebrow);

  final MusicFeedItem item;
}

final class StationPick extends TopPick {
  StationPick(this.artist) : super(MusicStrings.featuring(artist.title ?? ''));

  final MediaItem artist;
}

/// Start a mix.
Future<void> playMix(BuildContext context, MusicMix mix) async {
  await MusicPreviewPlayer.instance.cancel();
  if (!context.mounted) return;
  await playTracks(
    context,
    tracks: mix.tracks,
    playContext: MusicPlayContext(title: mix.fullTitle, kind: MusicPlayContextKind.mix),
  );
}

/// Atlas: a mix's cover, drawn rather than fetched: its two colors, a soft glow, the Atlas
/// mark and the name in big type (Apple Music's mix covers, our colors).
class MixArt extends StatelessWidget {
  const MixArt({super.key, required this.mix, required this.size, this.radius = 14});

  final MusicMix mix;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scale = size / 230;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: mix.colors),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -size * 0.25,
            top: -size * 0.2,
            child: Container(
              width: size * 0.9,
              height: size * 0.9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [Colors.white.withValues(alpha: 0.35), Colors.white.withValues(alpha: 0)]),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(16 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppIcon(Symbols.music_note_rounded, size: 16 * scale, color: Colors.white, fill: 1.0),
                    SizedBox(width: 3 * scale),
                    Text(
                      MusicStrings.atlasMusic,
                      style: TextStyle(color: Colors.white, fontSize: 14 * scale, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  mix.title.top,
                  maxLines: 2,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 34 * scale,
                    height: 1.0,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1 * scale,
                  ),
                ),
                Text(
                  mix.title.bottom,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 34 * scale,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1 * scale,
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

/// The color under an album's art in Top Picks, taken from the art (cached).
abstract final class _ArtColor {
  static final Map<String, Future<Color?>> _cache = {};

  static Future<Color?> of(BuildContext context, MusicFeedItem item) {
    final String? url;
    switch (item) {
      case ServerFeedItem(:final item):
        final client = context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId));
        final path = item.kind == MediaKind.track ? (item.parentThumbPath ?? item.thumbPath) : item.thumbPath;
        url = client == null || path == null ? null : client.thumbnailUrl(path, width: 64, height: 64);
      case ExternalAlbumItem(:final album):
        url = album.coverUrl;
      case ExternalArtistItem(:final artist):
        url = artist.imageUrl;
    }
    final resolved = url;
    if (resolved == null) return Future.value();
    return _cache.putIfAbsent(resolved, () async {
      try {
        final scheme = await ColorScheme.fromImageProvider(provider: NetworkImage(resolved), brightness: Brightness.dark);
        return scheme.primaryContainer;
      } catch (_) {
        return null;
      }
    });
  }
}

/// Atlas: Top Picks for You: tall cards, art on top and a colored band with the details under
/// it, each with its little label above.
class TopPicksShelf extends StatelessWidget {
  const TopPicksShelf({super.key, required this.picks, this.onNavigateToSidebar});

  final List<TopPick> picks;
  final VoidCallback? onNavigateToSidebar;

  static double cardWidth(BuildContext context) {
    if (PlatformDetector.isTV()) return 280;
    final width = MediaQuery.sizeOf(context).width;
    return width >= 900 ? 260 : (width * 0.62).clamp(200.0, 250.0);
  }

  @override
  Widget build(BuildContext context) {
    if (picks.isEmpty) return const SizedBox.shrink();
    final width = cardWidth(context);
    final padding = MusicPage.padding(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: padding,
            child: const MusicSectionHeader(title: MusicStrings.topPicks),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: width + 76 + 30,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: padding,
              clipBehavior: Clip.none,
              itemCount: picks.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) => _TopPickCard(
                pick: picks[index],
                width: width,
                onNavigateLeft: index == 0 ? onNavigateToSidebar : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopPickCard extends StatelessWidget {
  const _TopPickCard({required this.pick, required this.width, this.onNavigateLeft});

  final TopPick pick;
  final double width;
  final VoidCallback? onNavigateLeft;

  /// What the long-press menu is about (mixes have none).
  MusicFeedItem? get _menuItem => switch (pick) {
    MixPick() => null,
    ItemPick(:final item) => item,
    StationPick(:final artist) => ServerFeedItem(artist),
  };

  void _open(BuildContext context) {
    switch (pick) {
      case MixPick(:final mix):
        unawaited(playMix(context, mix));
      case ItemPick(:final item):
        unawaited(openFeedItem(context, item));
      case StationPick(:final artist):
        unawaited(MusicPreviewPlayer.instance.cancel().then((_) {
          if (context.mounted) unawaited(playInstantMix(context, artist));
        }));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const band = 76.0;
    final external = pick is ItemPick && (pick as ItemPick).item is ExternalAlbumItem
        ? ((pick as ItemPick).item as ExternalAlbumItem).album
        : null;

    final Widget art = switch (pick) {
      MixPick(:final mix) => MixArt(mix: mix, size: width, radius: 0),
      ItemPick(:final item) => MusicArt(item: item, size: width, radius: 0),
      StationPick(:final artist) => Stack(
        children: [
          MusicArt(item: ServerFeedItem(artist), size: width, radius: 0),
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIcon(Symbols.radio_rounded, size: 14, color: Colors.white, fill: 1.0),
                  const SizedBox(width: 4),
                  Text(
                    MusicStrings.station,
                    style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    };

    final (String line1, String? line2) = switch (pick) {
      MixPick(:final mix) => (mix.artistLine, null),
      ItemPick(item: ServerFeedItem(:final item)) => (
        item.kind == MediaKind.track ? (item.albumTitle ?? item.title ?? '') : (item.title ?? ''),
        item.kind == MediaKind.track ? item.trackArtistTitle : item.albumArtistTitle,
      ),
      ItemPick(item: ExternalAlbumItem(:final album)) => (album.title, album.artistName),
      ItemPick(item: ExternalArtistItem(:final artist)) => (artist.name, null),
      StationPick(:final artist) => (MusicStrings.stationLike(artist.title ?? ''), null),
    };

    Widget bandWith(Color color) => Container(
      width: width,
      height: band,
      color: color,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            line1,
            maxLines: line2 == null ? 3 : 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontWeight: line2 == null ? FontWeight.w500 : FontWeight.w700,
              height: 1.25,
            ),
          ),
          if (line2 != null && line2.isNotEmpty)
            Text(
              line2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
            ),
        ],
      ),
    );

    final fallback = Color.lerp(theme.colorScheme.primary, Colors.black, 0.55)!;
    Widget colored(MusicFeedItem item) => FutureBuilder<Color?>(
      future: _ArtColor.of(context, item),
      builder: (context, snapshot) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: KeyedSubtree(key: ValueKey(snapshot.data), child: bandWith(snapshot.data ?? fallback)),
      ),
    );
    final Widget bandWidget = switch (pick) {
      MixPick(:final mix) => bandWith(mix.bandColor),
      ItemPick(:final item) => colored(item),
      StationPick(:final artist) => colored(ServerFeedItem(artist)),
    };

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pick.eyebrow,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          FocusableWrapper(
            borderRadius: 14,
            onSelect: () => _open(context),
            onLongPress: _menuItem == null ? null : () => unawaited(MusicItemMenu.show(context, _menuItem!)),
            onNavigateLeft: onNavigateLeft,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 20, offset: const Offset(0, 10)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    canRequestFocus: false,
                    onTap: () => _open(context),
                    onLongPress: _menuItem == null ? null : () => unawaited(MusicItemMenu.show(context, _menuItem!)),
                    onSecondaryTapUp: _menuItem == null
                        ? null
                        : (details) => unawaited(
                            MusicItemMenu.show(context, _menuItem!, position: details.globalPosition),
                          ),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            art,
                            if (external != null) ...[
                              Positioned(
                                top: 10,
                                right: 10,
                                child: NotOnServerBadge(status: external.status, mbid: external.mbid),
                              ),
                              Positioned(left: 10, bottom: 10, child: AlbumPreviewButton(album: external)),
                            ],
                          ],
                        ),
                        bandWidget,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Atlas: Made for You: the mixes as square covers with their names under them.
class MixShelf extends StatelessWidget {
  const MixShelf({super.key, required this.mixes, this.onNavigateToSidebar});

  final List<MusicMix> mixes;
  final VoidCallback? onNavigateToSidebar;

  @override
  Widget build(BuildContext context) {
    if (mixes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final size = MusicFeedShelf.cardSize(context);
    final padding = MusicPage.padding(context);
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: padding,
            child: const MusicSectionHeader(title: MusicStrings.madeForYou),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: size + 62,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: padding,
              clipBehavior: Clip.none,
              itemCount: mixes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final mix = mixes[index];
                void play() => unawaited(playMix(context, mix));
                return SizedBox(
                  width: size,
                  child: FocusableWrapper(
                    borderRadius: 14,
                    onSelect: play,
                    onNavigateLeft: index == 0 ? onNavigateToSidebar : null,
                    child: InkWell(
                      canRequestFocus: false,
                      borderRadius: BorderRadius.circular(14),
                      onTap: play,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.22),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: MixArt(mix: mix, size: size),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            mix.fullTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            mix.artistLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
