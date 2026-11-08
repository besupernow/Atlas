import 'package:flutter/services.dart';

import '../../models.dart';
import '../video_rect_support.dart';
import 'atlas_gst_abr.dart';
import 'player_avfoundation.dart';

/// Linux backend on GStreamer (`linux/runner/gst/gst_av_plugin.cc`), for Atlas adaptive streaming.
///
/// mpv can't switch HLS renditions; GStreamer's hlsdemux2 can, seamlessly. The native side speaks
/// the AVPlayer plugin's protocol, so this is [PlayerAvFoundation] on another channel, plus:
///
/// - the video rect ([VideoRectSupport]): the picture is a Wayland subsurface below Flutter, like
///   mpv's plane, so it has to be told where to go;
/// - [AtlasGstAbr], which decides the rendition (warm-up first, then switch) and pins it natively.
///
/// Subtitles are drawn by the app (`AtlasSubtitleOverlay`). Direct play, downloads and live TV
/// stay on mpv.
class PlayerGStreamer extends PlayerAvFoundation with VideoRectSupport {
  PlayerGStreamer() {
    _abr = AtlasGstAbr(
      invoke: (method, args) => invoke(method, args),
      stats: getStats,
    );
  }

  static const _gstMethodChannel = MethodChannel('com.atlas/gst_player');
  static const _gstEventChannel = EventChannel('com.atlas/gst_player/events');

  late final AtlasGstAbr _abr;

  @override
  MethodChannel get methodChannel => _gstMethodChannel;

  @override
  EventChannel get eventChannel => _gstEventChannel;

  @override
  String get logPrefix => 'GStreamer';

  @override
  String get playerType => 'gstreamer';

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    _abr.stop();
    await super.open(
      media,
      play: play,
      isLive: isLive,
      externalSubtitles: externalSubtitles,
      timelineDuration: timelineDuration,
      timelineOffset: timelineOffset,
    );
    if (!disposed) _abr.start(media.uri, media.headers);
  }

  /// Native stats, plus the rendition the ABR logic pinned (GStreamer doesn't say which it plays).
  @override
  Future<Map<String, dynamic>> getStats() async {
    final stats = await super.getStats();
    final bandwidth = _abr.pinnedBandwidth;
    if (bandwidth != null) {
      stats['videoBitrate'] = bandwidth;
      stats['atlasLevel'] = _abr.pinnedLevel;
      final decoder = stats['videoDecoderName'];
      if (decoder is String) stats['videoDecoderName'] = '$decoder, level ${_abr.pinnedLevel}';
    }
    return stats;
  }

  @override
  Future<void> seek(Duration position) async {
    _abr.onSeek();
    await super.seek(position);
  }

  @override
  Future<void> stop() async {
    _abr.stop();
    await super.stop();
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    _abr.dispose();
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
  }
}
