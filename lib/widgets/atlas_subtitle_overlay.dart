import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

import '../mpv/mpv.dart';
import '../mpv/player/native_subtitle_rendering.dart';
import '../services/atlas_adaptive_streaming.dart';
import '../services/player_sync_offsets.dart';
import '../services/settings_service.dart';
import '../theme/mono_tokens.dart';
import '../utils/app_logger.dart';

/// Atlas: subtitles drawn by the app instead of the player.
///
/// Used during adaptive streaming, where every text subtitle is a sidecar file
/// the server converts on request (nothing is burned in). The overlay fetches
/// the selected sidecar as WebVTT, keeps it in sync with the playhead, and
/// draws it in the app's own type, styled from the active theme: the text takes
/// the theme's light tone, the box its dark tone, the corners its radius and a
/// faint edge its accent. Size, position, bold, italic and the background
/// opacity still come from the subtitle settings.
///
/// The backend keeps the track selected (so menus, the track list and resume
/// all work as before) but stops drawing it, through [NativeSubtitleRendering].
class AtlasSubtitleOverlay extends StatefulWidget {
  const AtlasSubtitleOverlay({super.key, required this.player});

  final Player player;

  @override
  State<AtlasSubtitleOverlay> createState() => _AtlasSubtitleOverlayState();
}

class _AtlasSubtitleOverlayState extends State<AtlasSubtitleOverlay> with SingleTickerProviderStateMixin {
  StreamSubscription<TrackSelection>? _trackSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<void>? _loadedSub;
  late final Ticker _ticker;
  PlayerSyncOffsets? _offsets;
  AtlasSubtitleSelection? _selection;

  String? _activeUri;
  List<_Cue> _cues = const [];
  int _loadGeneration = 0;
  bool _nativeHidden = false;

  // Playhead extrapolation between the backend's position ticks (~4 Hz), so
  // cues change on the frame they should.
  Duration _lastPosition = Duration.zero;
  Duration _lastPositionAt = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  bool _playing = false;

  String? _text;

  /// Backends whose subtitles this replaces: the adaptive-streaming players.
  bool get _eligible => atlasOverlayDrawsSubtitles(widget.player);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _attach();
  }

  @override
  void didUpdateWidget(covariant AtlasSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _detach(restoreNative: false);
      _attach();
    }
  }

  void _attach() {
    if (!_eligible) return;
    final player = widget.player;
    _offsets = PlayerSyncOffsets.of(player)..addListener(_refreshText);
    _playing = player.state.playing;
    _markPosition(player.state.position);
    _selection = AtlasSubtitleSelection.of(player)..addListener(_onAppSelection);
    _trackSub = player.streams.track.listen((selection) => _onNativeSelection(selection.subtitle));
    _positionSub = player.streams.position.listen(_markPosition);
    _playingSub = player.streams.playing.listen((playing) {
      _markPosition(_currentPosition());
      _playing = playing;
    });
    // A reload can bring up a fresh native renderer that draws again; tell it once more.
    _loadedSub = player.streams.fileLoaded.listen((_) {
      // A new file: the player's own selection is authoritative again.
      _selection?.release();
      if (_nativeHidden) _setNative(false);
    });
    _onAppSelection();
  }

  void _detach({required bool restoreNative}) {
    _trackSub?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _loadedSub?.cancel();
    _loadedSub = null;
    _trackSub = null;
    _positionSub = null;
    _playingSub = null;
    _offsets?.removeListener(_refreshText);
    _offsets = null;
    _selection?.removeListener(_onAppSelection);
    _selection = null;
    if (_ticker.isActive) _ticker.stop();
    _loadGeneration++;
    _activeUri = null;
    _cues = const [];
    _text = null;
    if (restoreNative && _nativeHidden) _setNative(true);
    _nativeHidden = false;
  }

  @override
  void dispose() {
    _detach(restoreNative: true);
    _ticker.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- selection

  void _onNativeSelection(SubtitleTrack? track) {
    if (_selection?.active ?? false) return;
    _onSelection(track);
  }

  void _onAppSelection() {
    final selection = _selection;
    _onSelection(selection != null && selection.active ? selection.track : widget.player.state.track.subtitle);
  }

  void _onSelection(SubtitleTrack? track) {
    final uri = track?.uri;
    final usable =
        track != null &&
        track.id != SubtitleTrack.off.id &&
        uri != null &&
        (uri.startsWith('http://') || uri.startsWith('https://')) &&
        !_isBitmap(track.codec);
    if (!usable) {
      if (_activeUri != null) {
        _loadGeneration++;
        _activeUri = null;
        _cues = const [];
        _setText(null);
        if (_ticker.isActive) _ticker.stop();
      }
      // A bitmap or embedded track is the backend's to draw, unless the app is in
      // charge (its "off" must stay off, whatever the player still has selected).
      if (_nativeHidden && !(_selection?.active ?? false)) {
        _nativeHidden = false;
        _setNative(true);
      }
      return;
    }
    if (!_nativeHidden) {
      _nativeHidden = true;
      _setNative(false);
    }
    if (uri == _activeUri) return;
    _activeUri = uri;
    _cues = const [];
    _setText(null);
    unawaited(_load(uri));
    if (!_ticker.isActive) _ticker.start();
  }

  static bool _isBitmap(String? codec) {
    final c = codec?.toLowerCase() ?? '';
    return c.contains('pgs') || c.contains('dvd') || c.contains('dvb') || c.contains('vobsub') || c == 'sup';
  }

  void _setNative(bool enabled) {
    // Player and NativeSubtitleRendering are unrelated types, so `is` can't promote; bind instead.
    if (widget.player case final NativeSubtitleRendering native) {
      unawaited(native.setNativeSubtitleRendering(enabled).catchError((Object _) {}));
    }
  }

  Future<void> _load(String uri) async {
    final generation = ++_loadGeneration;
    try {
      final response = await http.get(Uri.parse(_webVttUrl(uri)));
      if (!mounted || generation != _loadGeneration) return;
      if (response.statusCode != 200) {
        appLogger.w('Atlas subtitles: HTTP ${response.statusCode} for sidecar');
        return;
      }
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      _cues = _parseCues(body);
      _refreshText();
    } catch (e) {
      if (mounted && generation == _loadGeneration) appLogger.w('Atlas subtitles: load failed', error: e);
    }
  }

  /// Jellyfin converts subtitles on request; asking for `.vtt` means one format to parse.
  static String _webVttUrl(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return uri;
    final path = parsed.path.replaceFirst(
      RegExp(r'/Stream\.(srt|subrip|ass|ssa|sub|vtt|webvtt)$', caseSensitive: false),
      '/Stream.vtt',
    );
    return parsed.replace(path: path).toString();
  }

  // ------------------------------------------------------------------ timing

  void _markPosition(Duration position) {
    _lastPosition = position;
    _lastPositionAt = _clock.elapsed;
    _refreshText();
  }

  Duration _currentPosition() {
    if (!_playing) return _lastPosition;
    final elapsed = _clock.elapsed - _lastPositionAt;
    // Never run more than a second past the last real tick (stalls, seeks).
    final capped = elapsed > const Duration(seconds: 1) ? const Duration(seconds: 1) : elapsed;
    final rate = widget.player.state.rate;
    return _lastPosition + capped * (rate > 0 ? rate : 1.0);
  }

  void _onTick(Duration _) => _refreshText();

  void _refreshText() {
    if (_cues.isEmpty) return;
    final delayMs = _offsets?.subtitleMs ?? 0;
    // A positive sub-delay shows subtitles later, as mpv does.
    final t = (_currentPosition().inMilliseconds - delayMs) / 1000.0;
    final active = <String>[];
    for (final cue in _cues) {
      if (cue.start > t) break;
      if (t < cue.end) active.add(cue.text);
    }
    _setText(active.isEmpty ? null : active.join('\n'));
  }

  void _setText(String? text) {
    if (text == _text) return;
    if (!mounted) {
      _text = text;
      return;
    }
    setState(() => _text = text);
  }

  // ----------------------------------------------------------------- parsing

  static final _timing = RegExp(r'([\d:.,]+)\s*-->\s*([\d:.,]+)');
  static final _tags = RegExp(r'<[^>]+>');
  static final _assOverrides = RegExp(r'\{\\[^}]*\}');

  /// WebVTT (and SRT, which has the same cue shape) to plain-text cues, sorted by start.
  static List<_Cue> _parseCues(String body) {
    final normalized = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final cues = <_Cue>[];
    for (final block in normalized.split(RegExp(r'\n{2,}'))) {
      final lines = block.split('\n');
      final timingIndex = lines.indexWhere((line) => line.contains('-->'));
      if (timingIndex < 0) continue;
      final match = _timing.firstMatch(lines[timingIndex]);
      if (match == null) continue;
      final start = _parseTime(match.group(1)!);
      final end = _parseTime(match.group(2)!);
      if (start == null || end == null || end <= start) continue;
      final text = lines
          .skip(timingIndex + 1)
          .map(_cleanLine)
          .where((line) => line.isNotEmpty)
          .join('\n');
      if (text.isNotEmpty) cues.add(_Cue(start, end, text));
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static double? _parseTime(String raw) {
    final fields = raw.trim().replaceAll(',', '.').split(':');
    if (fields.length < 2 || fields.length > 3) return null;
    var seconds = 0.0;
    for (final field in fields) {
      final value = double.tryParse(field);
      if (value == null) return null;
      seconds = seconds * 60 + value;
    }
    return seconds;
  }

  static String _cleanLine(String line) => line
      .replaceAll(_tags, '')
      .replaceAll(_assOverrides, '')
      .replaceAll(r'\N', '\n')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .trim();

  // --------------------------------------------------------------- rendering

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) => _buildCue(context, text, constraints.biggest),
      ),
    );
  }

  Widget _buildCue(BuildContext context, String text, Size size) {
    final theme = Theme.of(context);
    final t = tokens(context);
    final settings = SettingsService.instance;
    final dark = theme.brightness == Brightness.dark;

    // The theme's light tone for text and its dark tone for the box, whichever
    // way round the theme itself is, so subtitles always read over video.
    final textColor = dark ? t.text : t.bg;
    final boxBase = dark ? t.bg : t.text;
    final userOpacity = settings.read(SettingsService.subtitleBackgroundOpacity);
    final boxAlpha = userOpacity > 0 ? (userOpacity / 100).clamp(0.0, 1.0) : 0.55;

    // Same scale as mpv's sub-font-size: points of a 720-line frame.
    final fontSize = (settings.read(SettingsService.subtitleFontSize) * size.height / 720).clamp(12.0, 72.0);
    final position = settings.read(SettingsService.subtitlePosition).clamp(0, 150);
    final bottom = size.height * (0.05 + (100 - position) / 100);

    final style = (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
      color: textColor,
      fontSize: fontSize,
      height: 1.25,
      fontWeight: settings.read(SettingsService.subtitleBold) ? FontWeight.w700 : FontWeight.w600,
      fontStyle: settings.read(SettingsService.subtitleItalic) ? FontStyle.italic : FontStyle.normal,
      shadows: [Shadow(color: boxBase.withValues(alpha: 0.9), blurRadius: fontSize * 0.18)],
    );

    return Stack(
      children: [
        Positioned(
          left: size.width * 0.06,
          right: size.width * 0.06,
          bottom: bottom.clamp(0.0, size.height * 0.85),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: boxBase.withValues(alpha: boxAlpha),
                borderRadius: BorderRadius.circular(t.radiusSm),
                border: Border.all(color: t.accent.withValues(alpha: 0.18), width: 1),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: fontSize * 0.55, vertical: fontSize * 0.22),
                child: Text(text, style: style, textAlign: TextAlign.center),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Whether [player] is one whose subtitles [AtlasSubtitleOverlay] draws
/// (adaptive streaming on ExoPlayer, AVPlayer or the web player).
bool atlasOverlayDrawsSubtitles(Player player) {
  final type = player.playerType;
  return player is NativeSubtitleRendering &&
      AtlasAdaptiveStreaming.enabled &&
      (type == 'exoplayer' || type == 'avplayer' || type == 'web');
}

/// Atlas adaptive streaming: a subtitle the app picked itself, drawn by the
/// overlay without the player ever loading it.
///
/// Switching subtitles this way never touches the stream: no reopen to attach a
/// sidecar, no transcode restart. While [active], the player's own selection is
/// ignored; a new file (reload, next episode) hands control back to it.
final class AtlasSubtitleSelection extends ChangeNotifier {
  AtlasSubtitleSelection._();

  factory AtlasSubtitleSelection.of(Player player) => _byPlayer[player] ??= AtlasSubtitleSelection._();

  static final Expando<AtlasSubtitleSelection> _byPlayer = Expando<AtlasSubtitleSelection>('AtlasSubtitleSelection');

  bool _active = false;
  SubtitleTrack? _track;

  bool get active => _active;

  /// The app's pick, or null for off. Only meaningful while [active].
  SubtitleTrack? get track => _track;

  void select(SubtitleTrack? track) {
    _active = true;
    _track = track == null || track.id == SubtitleTrack.off.id ? null : track;
    notifyListeners();
  }

  void release() {
    if (!_active) return;
    _active = false;
    _track = null;
    notifyListeners();
  }
}

class _Cue {
  const _Cue(this.start, this.end, this.text);

  final double start;
  final double end;
  final String text;
}
