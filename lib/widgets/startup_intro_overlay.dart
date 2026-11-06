import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mpv/mpv.dart';
import '../services/settings_service.dart';
import '../services/startup_intro/startup_intro.dart';
import '../services/startup_intro/startup_timing.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';

/// Plays the seasonal intro clip over the app once per launch, the way
/// Disney+ plays its logo animation: full screen, no controls, nothing that
/// says "video". The app keeps starting up underneath, so the clip covers
/// loading time instead of adding to it.
///
/// Any key, remote button, click or tap skips it. If there's no clip for
/// today, it's turned off, or it doesn't start within a few seconds, the
/// overlay just steps aside. The loading screen underneath waits for it
/// (see [StartupTiming]), so home never appears before the clip is done.
class StartupIntroOverlay extends StatefulWidget {
  final Widget child;

  const StartupIntroOverlay({super.key, required this.child});

  @override
  State<StartupIntroOverlay> createState() => _StartupIntroOverlayState();
}

class _StartupIntroOverlayState extends State<StartupIntroOverlay> {
  /// Once per process, even if the app shell is rebuilt.
  static bool _ranThisLaunch = false;

  /// A first launch may stream the clip, so give it a moment to start.
  static const _startTimeout = Duration(seconds: 8);
  static const _maxLength = Duration(seconds: 15);
  static const _fadeOut = Duration(milliseconds: 400);

  Player? _player;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _startTimer;
  Timer? _capTimer;

  /// A clip was picked and the overlay is on screen.
  bool _showing = false;

  /// The first frame is up (until then the overlay is plain black).
  bool _started = false;
  bool _finishing = false;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    // Web plays the intro from index.html while Flutter loads.
    if (kIsWeb || _ranThisLaunch || !_enabled) {
      _removed = true;
      if (!kIsWeb) StartupTiming.markIntroDone();
      return;
    }
    _ranThisLaunch = true;
    unawaited(_begin());
  }

  bool get _enabled => SettingsService.instanceOrNull?.read(SettingsService.startupAnimation) ?? true;

  Future<void> _begin() async {
    final clip = await StartupIntro.pick();
    if (!mounted) return;
    if (clip == null) {
      _remove();
      return;
    }

    HardwareKeyboard.instance.addHandler(_onKey);
    setState(() => _showing = true);

    try {
      final player = Player();
      _player = player;
      // Silent unless it's a TV and the clip has a soundtrack (Disney+ does
      // the same). Browsers only autoplay muted video anyway.
      final withSound = clip.sound && !kIsWeb && PlatformDetector.isTV();
      await player.setVolume(withSound ? 100 : 0);
      _subs
        ..add(player.streams.position.listen((pos) {
          if (!_started && pos > Duration.zero && mounted) setState(() => _started = true);
        }))
        ..add(player.streams.completed.listen((done) {
          if (done) _finish();
        }))
        ..add(player.streams.error.listen((e) {
          appLogger.d('Startup intro: playback error: $e');
          _finish();
        }));
      _startTimer = Timer(_startTimeout, () {
        if (!_started) _finish();
      });
      _capTimer = Timer(_maxLength, _finish);
      await player.open(Media(clip.source));
    } catch (e) {
      appLogger.w('Startup intro: could not play ${clip.id}', error: e);
      _finish();
    }
  }

  bool _onKey(KeyEvent event) {
    if (!_showing || _removed) return false;
    if (event is KeyDownEvent) _finish();
    // Swallow everything while the clip is up, so the screen underneath
    // doesn't act on the press that skipped it.
    return true;
  }

  void _finish() {
    if (_finishing || _removed || !mounted) return;
    _startTimer?.cancel();
    _capTimer?.cancel();
    if (!_showing) {
      _remove();
      return;
    }
    setState(() => _finishing = true);
  }

  void _remove() {
    if (_removed) return;
    _removed = true;
    StartupTiming.markIntroDone();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _startTimer?.cancel();
    _capTimer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_removed || !_showing) return widget.child;
    final player = _player;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _finish,
            child: AnimatedOpacity(
              opacity: _finishing ? 0 : 1,
              duration: _fadeOut,
              curve: Curves.easeOut,
              onEnd: () {
                if (_finishing) _remove();
              },
              child: ColoredBox(
                color: Colors.black,
                child: player == null
                    ? const SizedBox.expand()
                // Kept invisible until the first frame so a slow start
                // shows black, not a half-loaded surface.
                    : Opacity(
                  opacity: _started ? 1 : 0,
                  child: Video(player: player, backgroundColor: Colors.black),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
