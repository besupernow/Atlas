import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../utils/platform_detector.dart';
import '../../../widgets/app_icon.dart';
import '../discover/deezer.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import '../discover/music_previews.dart';
import '../music_strings.dart';
import 'music_item_menu.dart';
import 'music_page.dart';

/// Atlas: the songs chart as Apple Music lays it out: columns of four you swipe through, each
/// song with its cover, its place on the chart, and a preview button. Tapping a song opens its
/// album (ours if we have it, the request sheet if we don't).
class TopSongsShelf extends StatelessWidget {
  TopSongsShelf({super.key, required List<ChartTrack> tracks, this.onNavigateToSidebar, this.title, this.subtitle})
  // Only songs that can be previewed.
      : tracks = [for (final track in tracks) if (track.previewUrl != null) track];

  final List<ChartTrack> tracks;

  /// Defaults to "Top Songs".
  final String? title;
  final String? subtitle;
  final VoidCallback? onNavigateToSidebar;

  static const _rows = 4;
  static const _rowHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final width = MediaQuery.sizeOf(context).width;
    final columnWidth = PlatformDetector.isTV() ? 420.0 : (width >= 900 ? 380.0 : width * 0.84);
    final columns = (tracks.length / _rows).ceil();
    final padding = MusicPage.padding(context);
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: padding,
            child: MusicSectionHeader(
              title: title ?? MusicStrings.topSongs,
              subtitle: title == null ? (subtitle ?? MusicStrings.topSongsSubtitle) : subtitle,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: _rows * _rowHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: padding,
              itemCount: columns,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, column) => SizedBox(
                width: columnWidth,
                child: Column(
                  children: [
                    for (var row = 0; row < _rows; row++)
                      if (column * _rows + row < tracks.length)
                        SizedBox(
                          height: _rowHeight,
                          child: _TopSongRow(
                            track: tracks[column * _rows + row],
                            onNavigateLeft: column == 0 ? onNavigateToSidebar : null,
                            divider: row < _rows - 1,
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopSongRow extends StatelessWidget {
  const _TopSongRow({required this.track, this.onNavigateLeft, this.divider = true});

  final ChartTrack track;
  final VoidCallback? onNavigateLeft;
  final bool divider;

  void _preview(BuildContext context) {
    final url = track.previewUrl;
    if (url == null) return;
    unawaited(
      MusicPreviewPlayer.instance.toggle(context, track.previewKey, [PreviewClip(title: track.title, url: url)]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    void open() => unawaited(openFeedItem(context, ExternalAlbumItem(track.album)));
    final canPreview = MusicPreviews.supported && track.previewUrl != null;

    return FocusableWrapper(
      borderRadius: 10,
      onSelect: open,
      onLongPress: () => unawaited(MusicItemMenu.show(context, ExternalAlbumItem(track.album))),
      onNavigateLeft: onNavigateLeft,
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(10),
        onTap: open,
        onLongPress: () => unawaited(MusicItemMenu.show(context, ExternalAlbumItem(track.album))),
        onSecondaryTapUp: (details) => unawaited(
          MusicItemMenu.show(context, ExternalAlbumItem(track.album), position: details.globalPosition),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 50,
                height: 50,
                child: MusicArt(item: ExternalAlbumItem(track.album), size: 50, radius: 8),
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                '${track.rank}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: scheme.primary),
              ),
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: divider
                      ? Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4), width: 0.5))
                      : null,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          ArtistLinks(
                            credit: ArtistCredit([track.artistName], track.featuring),
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (canPreview)
                      ListenableBuilder(
                        listenable: MusicPreviewPlayer.instance,
                        builder: (context, _) {
                          final player = MusicPreviewPlayer.instance;
                          final playing = player.isPlaying(track.previewKey);
                          return IconButton(
                            tooltip: MusicStrings.preview,
                            onPressed: () => _preview(context),
                            icon: Stack(
                              alignment: Alignment.center,
                              children: [
                                if (playing)
                                  SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      value: player.loading ? null : player.progress,
                                      strokeWidth: 2,
                                    ),
                                  ),
                                AppIcon(
                                  playing ? Symbols.stop_rounded : Symbols.play_arrow_rounded,
                                  color: scheme.primary,
                                  fill: 1.0,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    AlbumRequestIcon(album: track.album),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
