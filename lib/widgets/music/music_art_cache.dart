import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_image_helper.dart';

/// Atlas: album art for music, built exactly the way `OptimizedMediaImage` builds it (same
/// URL buckets, same decode size), so warming it here means the real widget finds it ready:
/// on disk (no network) and, at the same size, already decoded in memory. Used to have Now
/// Playing, the mini player and the next songs' art ready before they're shown.
abstract final class MusicArtCache {
  /// The size the blurred backdrop uses: blurred that hard, more pixels add nothing, and a
  /// small image loads (and warms) fast.
  static const double backdropSize = 240;

  /// The provider for [track]'s art at [logicalSize] (square), or null when it has none.
  static ImageProvider? provider(
      BuildContext context,
      MediaItem track,
      double logicalSize, {
        required MediaServerClient? client,
      }) {
    final path = track.thumbPath;
    if (path == null || path.isEmpty || !logicalSize.isFinite || logicalSize <= 0) return null;
    final pixelRatio = MediaImageHelper.artworkPixelRatio(context, imageType: ImageType.square);
    final url = MediaImageHelper.getOptimizedImageUrl(
      client: client,
      thumbPath: path,
      maxWidth: logicalSize,
      maxHeight: logicalSize,
      pixelRatio: pixelRatio,
      imageType: ImageType.square,
    );
    if (url.isEmpty) return null;
    final px = (logicalSize * pixelRatio).round();
    final (memWidth, memHeight) = MediaImageHelper.getMemCacheDimensions(
      displayWidth: px,
      displayHeight: px,
      imageType: ImageType.square,
    );
    return MediaImageHelper.serverArtworkProvider(imageUrl: url, memWidth: memWidth, memHeight: memHeight);
  }

  /// Roughly how big Now Playing draws the cover on this screen.
  static double nowPlayingSize(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return math.max(120.0, math.min((size.width - 48) * 0.85, size.height * 0.5));
  }

  static final Set<String> _warmed = {};

  /// Fetches and decodes [track]'s art at the sizes music shows it (mini player, Now
  /// Playing's header, cover and backdrop) in the background. Quiet on failure.
  static void warm(BuildContext context, MediaItem track, {required MediaServerClient? client}) {
    if (track.thumbPath == null) return;
    final key = '${track.globalKey}|${MediaQuery.sizeOf(context).width.round()}';
    if (!_warmed.add(key)) return;
    if (_warmed.length > 300) _warmed.remove(_warmed.first);
    for (final size in [48.0, 56.0, backdropSize, nowPlayingSize(context)]) {
      final image = provider(context, track, size, client: client);
      if (image == null) continue;
      precacheImage(
        image,
        context,
        onError: (error, _) {
          _warmed.remove(key);
          appLogger.d('Music: warming art for ${track.title} failed', error: error);
        },
      );
    }
  }
}
