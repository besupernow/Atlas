import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../../models/audio_channel_limit.dart';
import '../../../utils/app_logger.dart';
import '../../models.dart';
import '../audio_rendering_mode.dart';
import '../player.dart';
import '../player_state.dart';
import '../player_stream_controllers.dart';
import '../player_streams.dart';
import '../web_video_surface.dart';

Player createWebPlayer({bool audioOnly = false}) => PlayerWeb(audioOnly: audioOnly);

@JS('Hls')
extension type _Hls._(JSObject _) implements JSObject {
  external factory _Hls([JSObject? config]);
  external static bool isSupported();
  external void loadSource(String url);
  external void attachMedia(web.HTMLMediaElement media);
  external void recoverMediaError();
  external void destroy();
  external void on(String event, JSFunction callback);
}

int _nextViewId = 0;

/// Browser playback backend: an HTMLVideoElement/HTMLAudioElement, with hls.js
/// for HLS where the browser has no native support (everything but Apple).
class PlayerWeb with PlayerStreamControllersMixin implements Player, WebVideoSurface {
  PlayerWeb({bool audioOnly = false}) : _audioOnly = audioOnly {
    _streams = createStreams();
    final web.HTMLMediaElement media = audioOnly ? web.HTMLAudioElement() : web.HTMLVideoElement();
    _media = media;
    media.preload = 'auto';
    if (media is web.HTMLVideoElement) {
      media.setAttribute('playsinline', '');
      media.style.setProperty('width', '100%');
      media.style.setProperty('height', '100%');
      media.style.setProperty('object-fit', 'contain');
      media.style.setProperty('background-color', 'black');
      // Let Flutter own every pointer event so tap-to-toggle-controls works.
      media.style.setProperty('pointer-events', 'none');
      _viewType = 'atlas-video-${_nextViewId++}';
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => media);
    }
    _wireEvents();
  }

  final bool _audioOnly;
  late final PlayerStreams _streams;
  late final web.HTMLMediaElement _media;
  String _viewType = '';

  PlayerState _state = const PlayerState();
  bool _disposed = false;
  Duration _timelineOffset = Duration.zero;
  Duration? _durationOverride;
  Duration? _pendingStart;
  bool _isLive = false;
  bool _triedMediaRecovery = false;
  bool _wantPlaying = false;
  _Hls? _hls;
  final _listeners = <(String, JSFunction)>[];
  final _sidecars = <String, web.HTMLTrackElement>{};

  @override
  PlayerState get state => _state;

  @override
  PlayerStreams get streams => _streams;

  @override
  Duration get currentPosition => _mediaPosition();

  @override
  Duration? get outgoingSourcePosition => null;

  @override
  Duration get timelineOffset => _timelineOffset;

  @override
  bool get audioPassthroughActive => false;

  @override
  String get playerType => 'web';

  @override
  bool get supportsSecondarySubtitles => false;

  @override
  bool get detectsFpsAfterRender => false;

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => false;

  @override
  bool get providesNativeStats => false;

  @override
  bool get disposed => _disposed;

  @override
  Widget buildVideoSurface(BuildContext context) {
    if (_audioOnly || _viewType.isEmpty) return const SizedBox.expand();
    return HtmlElementView(viewType: _viewType, hitTestBehavior: PlatformViewHitTestBehavior.transparent);
  }

  // ---------------------------------------------------------------- events

  void _on(String type, void Function(web.Event) handler) {
    final fn = handler.toJS;
    _media.addEventListener(type, fn);
    _listeners.add((type, fn));
  }

  void _wireEvents() {
    _on('loadstart', (_) {
      _setState(completed: false, hasRenderedFrame: false);
      fileStartedController.add(null);
    });
    _on('loadedmetadata', (_) {
      _syncDuration();
      _setState(seekable: !_isLive && _media.seekable.length > 0);
      final start = _pendingStart;
      _pendingStart = null;
      if (start != null && start > Duration.zero) {
        final target = (start - _timelineOffset).inMilliseconds / 1000.0;
        if ((_media.currentTime - target).abs() > 1.0) _media.currentTime = target;
      }
      fileLoadedController.add(null);
      primaryMediaReadyController.add(null);
    });
    _on('loadeddata', (_) {
      _setState(hasRenderedFrame: true);
      playbackRestartController.add(null);
    });
    _on('durationchange', (_) => _syncDuration());
    _on('play', (_) => _setState(playing: true, completed: false));
    _on('pause', (_) {
      _setState(playing: false);
      if (!_wantPlaying) return;
      // Not asked for by us: the browser pauses media when its element is
      // detached from the page (platform view re-parenting). Resume once it
      // is back and still supposed to be playing.
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        if (_disposed || !_wantPlaying || _media.ended || !_media.paused) return;
        if (_media.isConnected) unawaited(_tryPlay());
      });
    });
    _on('playing', (_) => _setState(buffering: false));
    _on('waiting', (_) => _setState(buffering: true));
    _on('canplay', (_) => _setState(buffering: false));
    _on('seeked', (_) {
      _emitPosition();
      playbackRestartController.add(null);
    });
    _on('timeupdate', (_) => _emitPosition());
    _on('progress', (_) => _emitBuffer());
    _on('ended', (_) {
      _wantPlaying = false;
      _setState(completed: true);
    });
    _on('volumechange', (_) => _setState(volume: _media.volume * 100.0));
    _on('ratechange', (_) => _setState(rate: _media.playbackRate));
    _on('error', (_) => _onMediaError());
  }

  void _onMediaError() {
    if (_disposed) return;
    final err = _media.error;
    final text = err == null ? 'Media error' : 'Media error ${err.code}: ${err.message}';
    logController.add(PlayerLog(level: PlayerLogLevel.error, prefix: 'web', text: text));
    errorController.add(PlayerError(text));
    fileLoadFailedController.add(null);
  }

  // ----------------------------------------------------------------- state

  void _setState({
    bool? playing,
    bool? completed,
    bool? buffering,
    Duration? position,
    Duration? duration,
    bool? seekable,
    Duration? buffer,
    double? volume,
    double? rate,
    bool? hasRenderedFrame,
    Tracks? tracks,
    TrackSelection? track,
  }) {
    if (_disposed) return;
    final prev = _state;
    _state = prev.copyWith(
      playing: playing,
      completed: completed,
      buffering: buffering,
      position: position,
      duration: duration,
      seekable: seekable,
      buffer: buffer,
      volume: volume,
      rate: rate,
      hasRenderedFrame: hasRenderedFrame,
      tracks: tracks,
      track: track,
    );
    if (playing != null && playing != prev.playing) playingController.add(playing);
    if (completed != null && completed != prev.completed) completedController.add(completed);
    if (buffering != null && buffering != prev.buffering) bufferingController.add(buffering);
    if (duration != null && duration != prev.duration) durationController.add(duration);
    if (seekable != null && seekable != prev.seekable) seekableController.add(seekable);
    if (volume != null && volume != prev.volume) volumeController.add(volume);
    if (rate != null && rate != prev.rate) rateController.add(rate);
    if (tracks != null) tracksController.add(tracks);
    if (track != null) trackController.add(track);
  }

  Duration _mediaPosition() {
    final t = _media.currentTime;
    if (t.isNaN || t.isInfinite) return _timelineOffset;
    return Duration(milliseconds: (t * 1000).round()) + _timelineOffset;
  }

  void _emitPosition() {
    if (_disposed) return;
    final p = _mediaPosition();
    _state = _state.copyWith(position: p);
    positionController.add(p);
  }

  void _syncDuration() {
    final override = _durationOverride;
    final d = _media.duration;
    final Duration value;
    if (override != null) {
      value = override;
    } else if (d.isNaN || d.isInfinite) {
      value = Duration.zero;
    } else {
      value = Duration(milliseconds: (d * 1000).round()) + _timelineOffset;
    }
    _setState(duration: value);
  }

  void _emitBuffer() {
    if (_disposed) return;
    final ranges = <BufferRange>[];
    var bufferEnd = Duration.zero;
    final now = _media.currentTime;
    final buffered = _media.buffered;
    for (var i = 0; i < buffered.length; i++) {
      final start = buffered.start(i);
      final end = buffered.end(i);
      final range = BufferRange(
        start: Duration(milliseconds: (start * 1000).round()) + _timelineOffset,
        end: Duration(milliseconds: (end * 1000).round()) + _timelineOffset,
      );
      ranges.add(range);
      if (now >= start && now <= end) bufferEnd = range.end;
    }
    _state = _state.copyWith(buffer: bufferEnd, bufferRanges: ranges);
    bufferController.add(bufferEnd);
    bufferRangesController.add(ranges);
  }

  // ------------------------------------------------------------------ open

  static bool get _isApple {
    final ua = web.window.navigator.userAgent;
    return ua.contains('AppleWebKit') && !ua.contains('Chrome/') && !ua.contains('Chromium/');
  }

  static bool get _hlsJsAvailable {
    if (!globalContext.hasProperty('Hls'.toJS).toDart) return false;
    try {
      return _Hls.isSupported();
    } catch (_) {
      return false;
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
    if (_disposed) return;
    _releaseSource();
    _timelineOffset = timelineOffset;
    _durationOverride = timelineDuration;
    _pendingStart = media.start;
    _isLive = isLive;
    _triedMediaRecovery = false;
    _setState(
      position: media.start ?? Duration.zero,
      duration: timelineDuration ?? Duration.zero,
      completed: false,
      hasRenderedFrame: false,
    );
    _installSidecars(externalSubtitles);

    final uri = media.uri;
    final isHls = Uri.tryParse(uri)?.path.toLowerCase().endsWith('.m3u8') ?? false;
    final nativeHls = _media.canPlayType('application/vnd.apple.mpegurl').isNotEmpty;

    if (isHls && !(nativeHls && _isApple) && _hlsJsAvailable) {
      _attachHlsJs(uri, media);
    } else {
      if (isHls && !nativeHls) {
        logController.add(
          PlayerLog(level: PlayerLogLevel.warn, prefix: 'web', text: 'No HLS support available (hls.js missing?)'),
        );
      }
      if ((media.headers ?? const {}).isNotEmpty) {
        logController.add(
          PlayerLog(level: PlayerLogLevel.warn, prefix: 'web', text: 'Custom headers are ignored for <video src>'),
        );
      }
      _media.src = uri;
      _media.load();
    }
    if (play) await _tryPlay();
  }

  void _attachHlsJs(String uri, Media media) {
    final config = JSObject();
    final start = media.start;
    if (start != null && start > Duration.zero) {
      final secs = (start - _timelineOffset).inMilliseconds / 1000.0;
      if (secs > 0) config.setProperty('startPosition'.toJS, secs.toJS);
    }
    final headers = media.headers;
    if (headers != null && headers.isNotEmpty) {
      config.setProperty(
        'xhrSetup'.toJS,
        ((web.XMLHttpRequest xhr, JSAny? url) {
          headers.forEach((name, value) => xhr.setRequestHeader(name, value));
        }).toJS,
      );
    }
    final hls = _Hls(config);
    _hls = hls;
    hls.on('hlsError', _onHlsError.toJS);
    hls.attachMedia(_media);
    hls.loadSource(uri);
  }

  void _onHlsError(JSAny? event, JSObject data) {
    if (_disposed) return;
    final fatal = data.getProperty<JSBoolean?>('fatal'.toJS)?.toDart ?? false;
    final type = data.getProperty<JSString?>('type'.toJS)?.toDart ?? '';
    final details = data.getProperty<JSString?>('details'.toJS)?.toDart ?? 'unknown';
    logController.add(
      PlayerLog(level: fatal ? PlayerLogLevel.error : PlayerLogLevel.warn, prefix: 'hls', text: '$type/$details'),
    );
    if (!fatal) return;
    if (type == 'mediaError' && !_triedMediaRecovery) {
      _triedMediaRecovery = true;
      _hls?.recoverMediaError();
      return;
    }
    errorController.add(PlayerError('HLS playback failed: $details'));
    fileLoadFailedController.add(null);
  }

  Future<void> _tryPlay() async {
    _wantPlaying = true;
    try {
      await _media.play().toDart;
    } catch (e) {
      // Autoplay policy or an aborted load; the UI keeps its paused state.
      logController.add(PlayerLog(level: PlayerLogLevel.warn, prefix: 'web', text: 'play() rejected: $e'));
    }
  }

  void _releaseSource() {
    _wantPlaying = false;
    _hls?.destroy();
    _hls = null;
    _media.pause();
    _media.removeAttribute('src');
    for (final track in _sidecars.values) {
      track.remove();
    }
    _sidecars.clear();
  }

  // ------------------------------------------------------------- subtitles

  /// Browsers only render WebVTT. Jellyfin converts text subtitles on request,
  /// so ask for the `.vtt` flavour of whatever URL the sidecar carries.
  static String _vttUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path.replaceFirstMapped(
      RegExp(r'/Stream\.(srt|subrip|ass|ssa|sub|vtt|webvtt)$', caseSensitive: false),
          (_) => '/Stream.vtt',
    );
    return uri.replace(path: path).toString();
  }

  void _installSidecars(List<SubtitleTrack>? subtitles) {
    final list = subtitles ?? const <SubtitleTrack>[];
    if (_media is web.HTMLVideoElement) {
      for (final sub in list) {
        final uri = sub.uri;
        if (uri == null) continue;
        final el = web.HTMLTrackElement()
          ..kind = 'subtitles'
          ..label = sub.title ?? sub.language ?? 'Subtitles'
          ..srclang = sub.language ?? ''
          ..src = _vttUrl(uri);
        _media.append(el);
        el.track.mode = 'disabled';
        _sidecars[sub.id] = el;
      }
    }
    _setState(tracks: Tracks(subtitle: list), track: const TrackSelection(subtitle: SubtitleTrack.off));
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    for (final entry in _sidecars.entries) {
      entry.value.track.mode = entry.key == track.id ? 'showing' : 'disabled';
    }
    _setState(track: TrackSelection(audio: _state.track.audio, subtitle: track));
  }

  @override
  Future<void> selectSecondarySubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {
    // Browsers expose no cross-platform audio track switching; the app has to
    // reopen with a different AudioStreamIndex instead.
    logController.add(
      PlayerLog(level: PlayerLogLevel.info, prefix: 'web', text: 'selectAudioTrack ignored (${track.id})'),
    );
  }

  // --------------------------------------------------------------- control

  @override
  Future<void> play() => _tryPlay();

  @override
  Future<void> pause() async {
    _wantPlaying = false;
    _media.pause();
  }

  @override
  Future<void> playOrPause() async {
    if (_media.paused) {
      await _tryPlay();
    } else {
      _wantPlaying = false;
      _media.pause();
    }
  }

  @override
  Future<void> stop() async {
    _wantPlaying = false;
    _media.pause();
    _media.currentTime = 0;
    _setState(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    final target = position - _timelineOffset;
    playheadJumpController.add(position);
    _media.currentTime = (target.inMilliseconds / 1000.0).clamp(0.0, double.maxFinite).toDouble();
    _setState(position: position, completed: false);
  }

  @override
  Future<void> setNext(Media? media) async {}

  @override
  Future<void> setVolume(double volume) async {
    _media.volume = (volume / 100.0).clamp(0.0, 1.0).toDouble();
  }

  @override
  Future<void> setRate(double rate) async {
    _media.playbackRate = rate;
  }

  @override
  Future<void> setBoxFitMode(int mode) async {
    final fit = switch (mode) {
      1 => 'cover',
      2 => 'fill',
      _ => 'contain',
    };
    _media.style.setProperty('object-fit', fit);
  }

  @override
  Future<void> setVideoZoom(double scale) async {
    _media.style.setProperty('transform', 'scale($scale)');
  }

  // ------------------------------------------------- mpv-shaped no-ops/stubs

  @override
  Future<void> setAudioDevice(AudioDevice device) async {}

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> setLogLevel(String level) async {}

  @override
  Future<void> command(List<String> args) async {}

  @override
  Future<void> awaitDisplayModeSwitch({int extraDelayMs = 0}) async {}

  @override
  Future<void> configureSubtitleFonts() async {}

  @override
  Future<void> setAudioPassthrough(bool enabled) async {}

  @override
  Future<AudioRenderingMode?> getAudioRenderingMode() async => null;

  @override
  Future<void> setAudioNormalization(bool enabled) async {}

  @override
  Future<void> setAudioChannelLimit(AudioChannelLimit limit, {required int centerBoostDb, required bool normalize}) async {}

  @override
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async => true;

  @override
  Future<void> updateFrame() async {}

  @override
  Future<bool> isHdrOutputSupported() async => false;

  @override
  Future<bool> setVideoFrameRate(
      double fps,
      int durationMs, {
        int extraDelayMs = 0,
        int videoWidth = 0,
        int videoHeight = 0,
        bool matchResolution = false,
      }) async => false;

  @override
  Future<void> clearVideoFrameRate() async {}

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
  }) async {}

  @override
  Future<Map<String, dynamic>> getStats() async => const {};

  @override
  Future<String> runtimePlayerType() async => 'web';

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> abandonAudioFocus() async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    if (_disposed) return;
    _disposed = true;
    for (final (type, fn) in _listeners) {
      _media.removeEventListener(type, fn);
    }
    _listeners.clear();
    _releaseSource();
    _media.load();
    await closeStreamControllers();
  }
}
