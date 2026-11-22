import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../media/media_item.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../utils/formatters.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/music/equalizer_icon.dart';
import '../../../widgets/music/music_glass.dart';
import '../discover/discover_models.dart';
import '../discover/deezer.dart';
import '../discover/discover_widgets.dart';
import '../discover/music_previews.dart';
import 'music_item_menu.dart';

/// Atlas: frosted glass over a detail page's blurred art, with a hint of the accent: the
/// panel music's lists sit in (a release's songs, an outside album's previews).
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.radius = 24});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tint = MusicGlass.tint(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: MusicGlass.edge(context)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A thin line between rows inside a [GlassPanel], inset past the number column.
class GlassDivider extends StatelessWidget {
  const GlassDivider({super.key, this.indent = 56});

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent, right: 16),
    child: Divider(height: 1, thickness: 0.5, color: Colors.white.withValues(alpha: 0.08)),
  );
}

/// Atlas: a release's songs, in one glass panel: number (an equalizer on the one playing),
/// title, anyone else credited, length, and a menu. The playing song takes the accent.
class ReleaseTrackList extends StatelessWidget {
  const ReleaseTrackList({
    super.key,
    required this.tracks,
    required this.onPlay,
    this.albumArtist,
    this.showNumbers = true,
  });

  final List<MediaItem> tracks;
  final String? albumArtist;
  final ValueChanged<MediaItem> onPlay;
  final bool showNumbers;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            for (final (index, track) in tracks.indexed) ...[
              if (index > 0) const GlassDivider(),
              _ReleaseTrackRow(
                track: track,
                number: showNumbers ? '${track.trackNumber ?? index + 1}' : null,
                albumArtist: albumArtist,
                onPlay: onPlay,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReleaseTrackRow extends StatelessWidget {
  const _ReleaseTrackRow({required this.track, required this.number, required this.albumArtist, required this.onPlay});

  final MediaItem track;
  final String? number;
  final String? albumArtist;
  final ValueChanged<MediaItem> onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = context.select<MusicPlaybackService, bool>((s) => s.currentTrack?.globalKey == track.globalKey);
    final playing = context.select<MusicPlaybackService, bool>((s) => s.isPlaying);
    final artist = track.trackArtistTitle;
    final showArtist = artist != null && artist.isNotEmpty && artist != albumArtist;
    final length = track.durationMs;
    final item = ServerFeedItem(track);

    return FocusableWrapper(
      borderRadius: 14,
      onSelect: () => onPlay(track),
      onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(14),
        onTap: () => onPlay(track),
        onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
        onSecondaryTapUp: (details) => unawaited(MusicItemMenu.show(context, item, position: details.globalPosition)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 10, 4, 10),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Center(
                  child: current
                      ? SizedBox(width: 18, height: 18, child: EqualizerIcon(animate: playing, color: scheme.primary))
                      : Text(
                    number ?? '',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: current ? scheme.primary : null,
                      ),
                    ),
                    if (showArtist)
                      ArtistLinks(
                        credit: ArtistCredit.parse(artist!, title: track.title),
                        accent: true,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (length != null && length > 0)
                Text(
                  formatDurationTimestamp(Duration(milliseconds: length)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(MusicItemMenu.show(context, item)),
                icon: AppIcon(Symbols.more_horiz_rounded, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Atlas: one song in a top-songs list (an artist page, an artist's sheet): its cover, its place,
/// title and artists. Ours plays ([server], through [onPlay]); one from outside previews on tap
/// and has the request button for its album.
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.track,
    required this.rank,
    this.server,
    this.onPlay,
    this.focusNode,
    this.onNavigateUp,
    this.onNavigateLeft,
  });

  final ChartTrack track;
  final int rank;
  final MediaItem? server;
  final ValueChanged<MediaItem>? onPlay;
  final FocusNode? focusNode;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateLeft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final server = this.server;
    final MusicFeedItem item = server != null ? ServerFeedItem(server) : ExternalAlbumItem(track.album);
    final preview = track.previewUrl;

    void tap() {
      if (server != null) {
        onPlay?.call(server);
      } else if (preview != null) {
        unawaited(MusicPreviewPlayer.instance.toggle(context, track.previewKey, [PreviewClip(title: track.title, url: preview)]));
      }
    }

    return FocusableWrapper(
      focusNode: focusNode,
      borderRadius: 14,
      onSelect: tap,
      onNavigateUp: onNavigateUp,
      onNavigateLeft: onNavigateLeft,
      onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(14),
        onTap: tap,
        onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
        onSecondaryTapUp: (details) => unawaited(MusicItemMenu.show(context, item, position: details.globalPosition)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
          child: Row(
            children: [
              MusicArt(item: item, size: 46, radius: 9),
              SizedBox(
                width: 34,
                child: Text(
                  '$rank',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.primary.withValues(alpha: 0.85),
                  ),
                ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: MusicPreviewPlayer.instance,
                  builder: (context, _) {
                    final previewing = server == null && MusicPreviewPlayer.instance.isPlaying(track.previewKey);
                    final current = context.select<MusicPlaybackService, bool>(
                          (s) => server != null && s.currentTrack?.globalKey == server.globalKey,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: previewing || current ? scheme.primary : null,
                          ),
                        ),
                        if (previewing)
                          Padding(
                            padding: const EdgeInsets.only(top: 5, bottom: 3, right: 12),
                            child: LinearProgressIndicator(
                              value: MusicPreviewPlayer.instance.loading ? null : MusicPreviewPlayer.instance.progress,
                              minHeight: 2,
                              borderRadius: BorderRadius.circular(1),
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
