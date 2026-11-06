import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/device_performance.dart';
import 'loading_art.dart';
import 'loading_handoff_stub.dart' if (dart.library.js_interop) 'loading_handoff_web.dart';

/// The startup loading screen: a big "ATLAS+" wordmark whose letters are
/// windows onto a row of the server's own backdrops, cross-faded into each
/// other and drifting slowly sideways. The letters ease in on first show;
/// a soft glow picks up the colours drifting through them; a thin bar and
/// a rotating, silly loading line sit underneath.
///
/// web/index.html draws the same thing before Flutter loads, and this screen
/// continues it (same images, same scroll position) so the swap is invisible.
class AtlasLoadingView extends StatefulWidget {
  /// Something the viewer actually needs to know (e.g. "Starting offline
  /// mode"). Shown instead of the fun lines while set.
  final String? notice;

  const AtlasLoadingView({super.key, this.notice});

  @override
  State<AtlasLoadingView> createState() => _AtlasLoadingViewState();
}

class _AtlasLoadingViewState extends State<AtlasLoadingView> with TickerProviderStateMixin {
  static const _word = 'ATLAS+';

  static const _lines = [
    'Popping the popcorn…',
    'Dimming the lights…',
    'Finding the comfy seats…',
    'Hunting for the remote…',
    'Fluffing the pillows…',
    'Buttering the popcorn…',
    'Warming up the projector…',
    'Rolling out the red carpet…',
    'Skipping the trailers…',
    'Shushing the row behind you…',
    'Rewinding the tapes…',
    'Adjusting the tracking…',
    'Grabbing a blanket…',
    'Arguing about what to watch…',
    'Silencing phones…',
    'Sneaking in snacks…',
    'Saving you a seat…',
    'Untangling the cables…',
  ];

  /// A fresh random line every few seconds, never the same one twice in a row.
  static const _lineEvery = Duration(milliseconds: 3200);
  final _random = math.Random();
  late int _line = _random.nextInt(_lines.length);
  Timer? _lineTimer;
  static const _fontFamily = 'AtlasWordmark';
  static Future<void>? _fontLoad;

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// Safety net only: every failure path (no network, no images, bad
  /// cache) brings the letters in plain straight away.
  static const _artWait = Duration(seconds: 10);
  Timer? _artWaitTimer;

  /// The art arrived after the letters were already in, so it fades in
  /// itself; art that was ready first just appears with the letters.
  bool _artFadesIn = false;
  bool _artArrived = false;

  /// Web: the HTML splash did the entrance and covers this screen until the
  /// art is ready, so nothing here should fade.
  bool _webContinues = false;

  /// Only drives repaints; the scroll position comes from the clock so it
  /// can continue the web splash's.
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  late DateTime _scrollStart;
  ui.Image? _strip;
  bool _fontReady = false;
  bool _signalled = false;

  @override
  void initState() {
    super.initState();
    final handoff = readLoadingHandoff();
    final startMs = handoff?.startMs;
    _scrollStart = startMs != null ? DateTime.fromMillisecondsSinceEpoch(startMs) : DateTime.now();
    // The web splash already played the entrance: this copy just appears
    // (no second animation), but still only once its art is ready.
    _webContinues = handoff?.entranceDone ?? false;
    // The letters only come in once their art is decoded and on the GPU
    // (see _loadArt), never empty-then-filled.
    _artWaitTimer = Timer(_artWait, _maybeStartEntrance);
    unawaited(_loadFont());
    unawaited(_loadArt(handoff?.urls));
    _lineTimer = Timer.periodic(_lineEvery, (_) {
      if (!mounted) return;
      setState(() => _line = (_line + 1 + _random.nextInt(_lines.length - 1)) % _lines.length);
    });
  }

  Future<void> _loadFont() async {
    _fontLoad ??= (FontLoader(_fontFamily)..addFont(rootBundle.load('assets/fonts/AtlasWordmark.ttf'))).load();
    try {
      await _fontLoad;
    } catch (_) {}
    if (mounted) setState(() => _fontReady = true);
    _maybeStartEntrance();
  }

  void _maybeStartEntrance() {
    if (!mounted || !_fontReady) return;
    if (_entrance.value > 0 || _entrance.isAnimating) return;
    // Waiting on the art, and the deadline hasn't passed yet.
    if (!_artArrived && (_artWaitTimer?.isActive ?? false)) return;
    _artWaitTimer?.cancel();
    if (_webContinues) {
      _entrance.value = 1;
    } else {
      unawaited(_entrance.forward());
    }
  }

  Future<void> _loadArt(List<String>? handoffUrls) async {
    // 1. The strip saved last time (native) or the one the web splash is
    //    showing (web): instant, nothing to download.
    var strip = await LoadingArt.cachedStrip();
    final fromCache = strip != null;
    // 2. Nothing cached (first launch): build one now.
    if (strip == null) {
      final urls = await LoadingArt.urls(handoff: handoffUrls);
      strip = urls.isEmpty ? null : await LoadingArt.buildStrip(urls);
      // Keep it so the next launch is instant.
      if (strip != null) unawaited(LoadingArt.saveForNextLaunch(strip));
    }
    // 3. Either way, get a fresh random set ready for the NEXT launch, once
    //    startup has calmed down (it decodes images on the UI thread).
    if (fromCache) {
      // Not cancelled on dispose on purpose: it should run after home is up.
      Timer(const Duration(seconds: 8), () => unawaited(LoadingArt.prepareNextLaunch()));
    }

    if (!mounted) {
      strip?.dispose();
      _signal();
      return;
    }
    if (strip == null) {
      _signal();
      _artArrived = true;
      _maybeStartEntrance();
      return;
    }
    final lettersAlreadyIn = _entrance.value > 0 || _entrance.isAnimating;
    setState(() {
      _strip = strip;
      _artFadesIn = lettersAlreadyIn && !_webContinues;
    });
    if (!_staticArt) unawaited(_clock.repeat());
    // One frame to paint the art (invisibly, which uploads it to the GPU),
    // then bring the letters in and let the web splash go.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _signal();
      _artArrived = true;
      _maybeStartEntrance();
    });
  }

  void _signal() {
    if (_signalled) return;
    _signalled = true;
    signalLoadingArtReady();
  }

  bool get _staticArt => DevicePerformance.isReduced;

  @override
  void dispose() {
    // Leaving (e.g. straight to home): don't keep the web splash waiting.
    _signal();
    _artWaitTimer?.cancel();
    _lineTimer?.cancel();
    _entrance.dispose();
    _clock.dispose();
    _strip?.dispose();
    super.dispose();
  }

  double get _seconds => DateTime.now().difference(_scrollStart).inMicroseconds / 1e6;

  /// Brightness breathing for the art (1 when not animating).
  double _shimmer(bool animate) {
    if (!animate) return 1;
    final wave = 0.5 + 0.5 * math.sin(2 * math.pi * _seconds / kArtShimmerPeriod);
    return kArtShimmerLow + (1 - kArtShimmerLow) * wave;
  }

  Float64List _matrix(Rect bounds, ui.Image strip, bool animate) {
    final scale = bounds.height * kArtHeightFactor / kArtTileHeight;
    final period = strip.width * scale;
    var x = 0.0;
    var float = 0.0;
    if (animate && period > 0) {
      final seconds = _seconds;
      x = (seconds * kArtScrollSpeed) % period;
      float = math.sin(2 * math.pi * seconds / kArtFloatPeriod) * bounds.height * kArtFloatAmount;
    }
    final ty = (bounds.height - kArtTileHeight * scale) / 2 + float;
    // Column-major: scale, then translate.
    return Float64List.fromList([scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1, 0, -x, ty, 0, 1]);
  }

  // Saturation 1.4 (same as CSS saturate(1.4)).
  static const List<double> _saturate14 = [
    1.3148, -0.2860, -0.0288, 0, 0, //
    -0.0852, 1.1140, -0.0288, 0, 0, //
    -0.0852, -0.2860, 1.3712, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  /// The letters filled with the drifting art.
  Widget _artLetters(ui.Image strip, TextStyle style, bool animate) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => ImageShader(
        strip,
        TileMode.repeated,
        TileMode.clamp,
        _matrix(bounds, strip, animate),
        filterQuality: FilterQuality.medium,
      ),
      child: Text(_word, style: style),
    );
  }

  /// Art that lands after the letters are in fades in; art that was ready
  /// first just appears with them.
  Widget _fadeIn(String layer, ui.Image strip, Widget child) {
    return TweenAnimationBuilder<double>(
      key: ValueKey((layer, strip)),
      tween: Tween(begin: _artFadesIn ? 0 : 1, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      builder: (context, fade, child) => Opacity(opacity: fade, child: child),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final fontSize = (size.width * 0.21).clamp(64.0, 240.0);
    final animate = !_staticArt && !MediaQuery.disableAnimationsOf(context);
    // The blur is the expensive part; weak TVs skip the glow.
    final glow = !_staticArt;

    final word = AnimatedBuilder(
      animation: _entrance,
      builder: (context, _) {
        final t = Curves.easeOutQuint.transform(_entrance.value);
        final style = TextStyle(
          fontFamily: _fontFamily,
          fontSize: fontSize,
          height: 1,
          // Letters settle from slightly tight to their resting spacing.
          letterSpacing: fontSize * ui.lerpDouble(-0.04, 0.02, t)!,
          color: Colors.white,
        );
        final strip = _strip;
        return Opacity(
          // A hair above zero while waiting, so the art is already painted
          // (and uploaded) under the hidden letters; Opacity(0) skips paint.
          opacity: _fontReady ? math.max(t, 0.001) : 0,
          child: Transform(
            alignment: Alignment.center,
            // Letters rise and grow into place.
            transform: Matrix4.translationValues(0, (1 - t) * fontSize * 0.06, 0)
              ..multiply(Matrix4.diagonal3Values(0.94 + 0.06 * t, 0.94 + 0.06 * t, 1)),
            child: Stack(
              alignment: Alignment.center,
              // The glow spills past the letters.
              clipBehavior: Clip.none,
              children: [
                // Glow: a blurred copy of the art-filled letters underneath,
                // so it takes the colours of whatever is drifting through.
                if (strip != null && glow)
                  _fadeIn(
                    'glow',
                    strip,
                    AnimatedBuilder(
                      animation: _clock,
                      builder: (context, _) => ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          // Matches the web splash's blur(0.12em).
                          sigmaX: fontSize * 0.12,
                          sigmaY: fontSize * 0.12,
                          tileMode: TileMode.decal,
                        ),
                        child: Opacity(
                          opacity: 0.55 * _shimmer(animate),
                          // A little extra saturation so the glow reads as
                          // colour, not grey haze (web: saturate(1.4)).
                          child: ColorFiltered(
                            colorFilter: const ColorFilter.matrix(_saturate14),
                            child: _artLetters(strip, style, animate),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Plain letters until the art arrives (or if it never does).
                Text(_word, style: style.copyWith(color: scheme.onSurface.withValues(alpha: 0.12))),
                if (strip != null)
                  _fadeIn(
                    'art',
                    strip,
                    AnimatedBuilder(
                      animation: _clock,
                      builder: (context, _) =>
                          Opacity(opacity: _shimmer(animate), child: _artLetters(strip, style, animate)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    // Status and bar fade in after a beat, so a quick launch is just the word.
    final details = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1400),
      curve: const Interval(0.6, 1, curve: Curves.easeOut),
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 96,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: scheme.onSurface.withValues(alpha: 0.8),
                backgroundColor: scheme.onSurface.withValues(alpha: 0.10),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: 320,
            height: 20,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                widget.notice ?? _lines[_line],
                key: ValueKey(widget.notice ?? _lines[_line]),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface.withValues(alpha: 0.55)),
              ),
            ),
          ),
        ],
      ),
    );

    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              word,
              SizedBox(height: fontSize * 0.28),
              details,
            ],
          ),
        ),
      ),
    );
  }
}
