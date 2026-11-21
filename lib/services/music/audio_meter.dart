import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../mpv/player/player.dart';

/// Atlas: how loud the music is right now, as three bar heights (0..1) for the little
/// equalizer: the peak, the level, and a slower-moving level. Read from mpv's own decoder
/// through a lavfi `astats` tap, so the bars move with the song instead of looping.
///
/// It only asks mpv while someone is watching and music is playing, and stays empty
/// ([live] false) where the tap isn't available (no mpv, a build without lavfi's astats,
/// passthrough audio); the equalizer then falls back to its own animation.
class AudioMeter extends ValueNotifier<List<double>> {
  AudioMeter() : super(const [0, 0, 0]);

  static const _label = 'atlasmeter';
  static const _filter = '@$_label:lavfi=[astats=metadata=1:reset=1]';

  Player? _player;
  bool _playing = false;
  bool _tapped = false;
  Timer? _timer;
  DateTime _lastReading = DateTime.fromMillisecondsSinceEpoch(0);
  double _slow = 0;

  /// Readings arrived recently: the bars can follow them.
  bool get live => DateTime.now().difference(_lastReading) < const Duration(milliseconds: 600);

  /// Where mpv's ffmpeg is known to carry astats: the desktop builds. The Android and iOS
  /// libmpv builds are trimmed (no astats), and so is the bundled Linux one.
  static bool get _platformHasIt => !kIsWeb && (Platform.isWindows || Platform.isMacOS);

  /// Set the first time adding the tap fails, so it's never tried again this run (a failed
  /// filter can take the audio chain down with it).
  static bool _unavailable = false;

  static bool get supported => _platformHasIt && !_unavailable;

  bool _passthrough = false;
  bool _tapping = false;

  /// A new player (or none). The tap goes on once music is actually playing, so if it fails it
  /// fails right away and comes straight back off, instead of breaking the next track's start.
  void attach(Player? player, {bool passthrough = false}) {
    if (identical(player, _player)) return;
    _player = player;
    _passthrough = passthrough;
    _tapped = false;
    _sync();
  }

  Future<void> _tap(Player player) async {
    _tapping = true;
    try {
      await player.command(['af', 'add', _filter]);
      if (identical(player, _player)) _tapped = true;
    } catch (error) {
      _unavailable = true;
      debugPrint('Audio meter: not available ($error)');
      try {
        await player.command(['af', 'remove', '@$_label']);
      } catch (_) {
        // Never got added: nothing to take off.
      }
      _sync();
    } finally {
      _tapping = false;
    }
  }

  set playing(bool value) {
    if (_playing == value) return;
    _playing = value;
    _sync();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _sync();
  }

  void _sync() {
    final player = _player;
    final want = _playing && hasListeners && player != null && !_passthrough && supported;
    if (want && !_tapped && !_tapping && !player.disposed) unawaited(_tap(player));
    if (want && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 70), (_) => unawaited(_read()));
    } else if (!want && _timer != null) {
      _timer?.cancel();
      _timer = null;
      if (value.any((bar) => bar > 0)) value = const [0, 0, 0];
    }
  }

  bool _reading = false;

  Future<void> _read() async {
    final player = _player;
    if (_reading || player == null || !_tapped || player.disposed) return;
    _reading = true;
    try {
      final rms = double.tryParse(
        await player.getProperty('af-metadata/$_label/by-key/lavfi.astats.Overall.RMS_level') ?? '',
      );
      final peak = double.tryParse(
        await player.getProperty('af-metadata/$_label/by-key/lavfi.astats.Overall.Peak_level') ?? '',
      );
      if (rms == null || rms.isNaN) return;
      _lastReading = DateTime.now();
      final level = _scale(rms);
      final top = _scale(peak ?? rms);
      _slow = _slow * 0.8 + level * 0.2;
      // Ease toward the new values so the bars move, not jump.
      final previous = value;
      double ease(double from, double to) => to > from ? from + (to - from) * 0.7 : from + (to - from) * 0.35;
      value = [ease(previous[0], top), ease(previous[1], level), ease(previous[2], _slow)];
    } catch (_) {
      // A read that fails (between tracks, say) just waits for the next one.
    } finally {
      _reading = false;
    }
  }

  /// dBFS to 0..1: -48 dB is silence, -6 dB is full.
  static double _scale(double db) => ((db + 48) / 42).clamp(0.0, 1.0);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
