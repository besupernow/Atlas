import 'package:flutter/services.dart';

import '../../../models/audio_channel_limit.dart';
import '../../../services/atlas_adaptive_streaming.dart';
import '../../models.dart';
import '../native_subtitle_rendering.dart';
import '../player_base.dart';

/// iPhone / iPad backend on AVPlayer (`AtlasAVPlayerPlugin.swift`).
///
/// Exists for Atlas adaptive streaming: AVPlayer switches HLS renditions on its
/// own from its bandwidth estimate, which mpv cannot. The native side speaks the
/// same protocol as the ExoPlayer plugin (mpv-style property observations plus
/// `file-loaded` / `playback-restart` / `end-file` events), so everything above
/// [PlayerBase] works unchanged.
///
/// Subtitles are sidecar text files (WebVTT/SRT) the native side fetches and
/// draws itself; nothing is burned into an adaptive stream. mpv-only knobs
/// (`hwdec`, `sub-*`, filters, shaders) are accepted and ignored.
class PlayerAvFoundation extends PlayerBase implements NativeSubtitleRendering {
  static const _methodChannel = MethodChannel('com.atlas/av_player');
  static const _eventChannel = EventChannel('com.atlas/av_player/events');

  /// Subtitles hidden through `sub-visibility`; sticky across opens like mpv's.
  bool _subtitlesHidden = false;
  String? _hiddenSubtitleTrackId;

  Future<void>? _initFuture;

  @override
  MethodChannel get methodChannel => _methodChannel;

  @override
  EventChannel get eventChannel => _eventChannel;

  @override
  String get logPrefix => 'AVPlayer';

  @override
  String get playerType => 'avplayer';

  // The native dispose ignores an instanceId that did not create the core.
  @override
  bool get nativeDisposeIsStaleGuarded => true;

  @override
  bool get supportsSecondarySubtitles => false;

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => false;

  @override
  bool get detectsFpsAfterRender => true;

  @override
  bool get providesNativeStats => true;

  @override
  bool get audioPassthroughActive => false;

  Future<void> _ensureInitialized() async {
    if (initialized) return;
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      final result = await invoke<bool>('initialize', {'instanceId': nativeInstanceId});
      if (disposed) throw StateError('Player was disposed during initialization');
      if (result != true) throw const PlayerInitializationException();
      await observeCoreProperties(trackListFormat: 'string');
      await observeProperty('demuxer-cache-time', 'double');
      if (disposed) throw StateError('Player was disposed during initialization');
      initialized = true;
      AtlasAdaptiveStreaming.avPlayerActive = true;
    } catch (e) {
      _initFuture = null;
      if (!disposed) errorController.add(PlayerError(e.toString(), cause: PlayerError.playerInitFailed));
      rethrow;
    }
  }

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    if (disposed) return;
    await _ensureInitialized();
    final startPosition = media.start ?? timelineOffset;
    final previousState = state;
    final previousPosition = currentPosition;
    final previousTimelineDuration = configuredTimelineDuration;
    final previousTimelineOffset = this.timelineOffset;
    final previousExternalSubtitleMetadata = snapshotExternalSubtitleMetadata();
    configureTimeline(duration: timelineDuration, offset: timelineOffset);
    final sourceStart = sourcePositionFor(startPosition);
    clearTracks();
    setExternalSubtitleMetadata(externalSubtitles);
    resetPlaybackProgress(startPosition);
    setSeekable(false);
    // mpv reports `start-file` when a load begins; AVPlayer and GStreamer have no such event.
    // The open's outcome only counts file-loaded / playback-restart after a start-file, so
    // without this the screen waits on a first frame forever while the video plays behind it.
    handlePlayerEvent('start-file', null);

    try {
      await setVisible(true);
      await invoke('open', {
        'uri': media.uri,
        'headers': media.headers,
        'startPositionMs': sourceStart.inMilliseconds,
        'autoPlay': play,
        'isLive': isLive,
        if (externalSubtitles != null && externalSubtitles.isNotEmpty)
          'externalSubtitles': externalSubtitles
              .where((s) => s.uri?.isNotEmpty == true)
              .map(
                (s) => {
                  'uri': s.uri,
                  'title': s.title,
                  'language': s.language,
                  'codec': s.codec,
                  'isDefault': s.isDefault,
                  'isForced': s.isForced,
                },
              )
              .toList(),
      });
    } catch (_) {
      if (!disposed) {
        configureTimeline(duration: previousTimelineDuration, offset: previousTimelineOffset);
        restorePlaybackProgress(previousState, position: previousPosition);
        restoreTracks(previousState);
        restoreExternalSubtitleMetadata(previousExternalSubtitleMetadata);
        setSeekable(previousState.seekable);
      }
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    await invoke('play');
  }

  @override
  Future<void> pause() async {
    await invoke('pause');
  }

  @override
  Future<void> stop() async {
    await invoke('stop');
    setSeekable(false);
    await setVisible(false);
  }

  @override
  Future<void> seek(Duration position) async {
    await runSeek(position, () => invoke('seek', {'positionMs': sourcePositionFor(position).inMilliseconds}));
  }

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {
    await invoke('selectAudioTrack', {'trackId': track.id});
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    if (_subtitlesHidden) {
      _hiddenSubtitleTrackId = track.id == SubtitleTrack.off.id ? null : track.id;
      return _selectSubtitleNatively(SubtitleTrack.off);
    }
    return _selectSubtitleNatively(track);
  }

  Future<void> _selectSubtitleNatively(SubtitleTrack track) async {
    await invoke('selectSubtitleTrack', {'trackId': track.id});
  }

  @override
  Future<void> setVolume(double volume) async {
    await invoke('setVolume', {'volume': volume});
    if (!disposed) setVolumeState(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    await invoke('setRate', {'rate': rate});
    if (!disposed) setRateState(rate);
  }

  @override
  Future<void> setProperty(String name, String value) async {
    if (disposed) return;
    switch (name) {
      case 'pause':
        await (value == 'yes' ? pause() : play());
      case 'volume':
        await setVolume(double.tryParse(value) ?? 100);
      case 'speed':
        await setRate(double.tryParse(value) ?? 1.0);
      case 'sub-delay':
        await invoke('setSubtitleDelay', {'seconds': double.tryParse(value) ?? 0});
      case 'sub-visibility':
        if (value == 'no') {
          if (_subtitlesHidden) return;
          _subtitlesHidden = true;
          final current = state.track.subtitle;
          _hiddenSubtitleTrackId = current != null && current.id != SubtitleTrack.off.id ? current.id : null;
          if (_hiddenSubtitleTrackId != null) await _selectSubtitleNatively(SubtitleTrack.off);
        } else {
          if (!_subtitlesHidden) return;
          _subtitlesHidden = false;
          final storedId = _hiddenSubtitleTrackId;
          _hiddenSubtitleTrackId = null;
          if (storedId == null) return;
          for (final track in state.tracks.subtitle) {
            if (track.id == storedId) {
              await _selectSubtitleNatively(track);
              return;
            }
          }
        }
      default:
        // mpv properties (hwdec, sub-font, af, ...) have no AVPlayer meaning.
        break;
    }
  }

  @override
  Future<String?> getProperty(String name) async {
    if (disposed) return null;
    switch (name) {
      case 'pause':
        return state.playing ? 'no' : 'yes';
      case 'volume':
        return state.volume.toString();
      case 'speed':
        return state.rate.toString();
      case 'time-pos':
        return (state.position.inMilliseconds / 1000.0).toString();
      case 'duration':
        return (state.duration.inMilliseconds / 1000.0).toString();
      case 'seekable':
        return state.seekable ? 'yes' : 'no';
      case 'container-fps':
        return (await getStats())['videoFps']?.toString();
      case 'width':
      case 'dwidth':
        return (await getStats())['videoWidth']?.toString();
      case 'height':
      case 'dheight':
        return (await getStats())['videoHeight']?.toString();
      default:
        return null;
    }
  }

  @override
  Future<Map<String, dynamic>> getStats() async {
    if (disposed) return {};
    try {
      final result = await invoke<Map>('getStats');
      return Map<String, dynamic>.from(result ?? {});
    } catch (_) {
      return {};
    }
  }

  // No filter chain on AVPlayer: normalization, downmix and passthrough are the system's.
  @override
  // ignore: no-empty-block - no filter chain on AVPlayer
  Future<void> setAudioNormalization(bool enabled) async {}

  @override
  // ignore: no-empty-block - no filter chain on AVPlayer
  Future<void> setAudioChannelLimit(
    AudioChannelLimit limit, {
    required int centerBoostDb,
    required bool normalize,
  }) async {}

  @override
  // ignore: no-empty-block - the system decides passthrough
  Future<void> setAudioPassthrough(bool enabled) async {}

  @override
  // ignore: no-empty-block - mpv commands target the mpv backend
  Future<void> command(List<String> args) async {}

  @override
  Future<void> setSubtitleStyle({
    required double fontSize,
    required String textColor,
    required double borderSize,
    required String borderColor,
    required String bgColor,
    required int bgOpacity,
    int subtitlePosition = 100,
    bool bold = false,
    bool italic = false,
    bool anchorToScreen = false,
  }) async {
    if (disposed || !initialized) return;
    await invoke('setSubtitleStyle', {
      'fontSize': fontSize,
      'textColor': textColor,
      'borderSize': borderSize,
      'borderColor': borderColor,
      'bgColor': bgColor,
      'bgOpacity': bgOpacity,
      'subtitlePosition': subtitlePosition,
      'bold': bold,
      'italic': italic,
    });
  }

  @override
  Future<void> setBoxFitMode(int mode) async {
    if (disposed || !initialized) return;
    await invoke('setBoxFitMode', {'mode': mode});
  }

  @override
  Future<void> setVideoZoom(double scale) async {
    if (disposed || !initialized) return;
    await invoke('setVideoZoom', {'scale': scale});
  }

  @override
  Future<void> setNativeSubtitleRendering(bool enabled) async {
    if (disposed || !initialized) return;
    await invoke('setSubtitleRendering', {'enabled': enabled});
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    if (initialized) AtlasAdaptiveStreaming.avPlayerActive = false;
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
  }

  @override
  Future<void> updateFrame() async {
    if (disposed || !initialized) return;
    await invoke('updateFrame');
  }
}
