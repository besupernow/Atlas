import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:plezy/utils/app_platform.dart';

import 'settings_service.dart';
import 'video_decode_capabilities.dart';

/// Atlas adaptive streaming (ABR).
///
/// The Atlas server builds a real quality ladder for a master playlist asked
/// for with `AtlasAbr=true`: the original file (stream copied) on top when its
/// keyframes line up, transcodes below it, every level cut at the same frames.
/// The player picks a level from its own bandwidth estimate and switches at any
/// segment boundary, so a weak connection drops quality instead of stalling.
///
/// That needs a player with HLS rendition switching, so it only applies where
/// one is the backend:
/// - web: hls.js (Safari: its native HLS)
/// - Android: ExoPlayer (mpv has no ABR)
/// - iPhone / iPad: AVPlayer (see `PlayerAvFoundation`)
///
/// Desktop keeps mpv and direct play for now.
abstract final class AtlasAdaptiveStreaming {
  /// Whether the user left adaptive streaming on.
  static bool get _settingOn {
    try {
      return SettingsService.instance.read(SettingsService.adaptiveStreaming);
    } catch (_) {
      return true;
    }
  }

  /// Whether this platform's video backend is AVPlayer (iPhone / iPad with
  /// adaptive streaming on). Decides which [Player] the factory builds.
  static bool get usesAvPlayer => !kIsWeb && Platform.isIOS && _settingOn;

  /// Whether an AVPlayer core is the live video backend right now (set by
  /// `PlayerAvFoundation`). Picture in Picture follows it to the right plugin.
  static bool avPlayerActive = false;

  /// Whether video playback asks the server for the adaptive ladder.
  static bool get enabled {
    if (!_settingOn) return false;
    if (kIsWeb) return true;
    if (Platform.isIOS) return true;
    if (Platform.isAndroid) {
      try {
        return SettingsService.instance.read(SettingsService.useExoPlayer);
      } catch (_) {
        return true;
      }
    }
    return false;
  }

  /// Video codecs a native ABR player takes in the stream. The library is
  /// conformed to H.264; HEVC is listed where the device decodes it so a HEVC
  /// original can still be the top (stream copied) level.
  static List<String> get nativeVideoCodecs => [
    'h264',
    if (VideoDecodeCapabilities.accepts(RankedVideoCodec.hevc)) 'hevc',
  ];

  /// Audio codecs a native ABR player takes in fMP4 HLS. AAC is what the
  /// library carries; AC-3/E-AC-3 copy through on AVPlayer and ExoPlayer.
  static const List<String> nativeAudioCodecs = ['aac', 'mp3', 'ac3', 'eac3'];
}
