import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'now_playing_screen.dart';

/// Atlas: how Now Playing comes and goes. It rises from the bottom like a card (rounded top
/// corners that square off as it lands, the page under it dimming), and swiping down
/// drags the card itself: it follows the finger, the page under it comes back into view,
/// and letting go either settles it back or lets it fall away at the speed it was thrown.
/// The old route faded a short slide in, which read as a jump.
class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute({super.settings, Duration duration = const Duration(milliseconds: 460)})
      : _duration = duration;

  final Duration _duration;

  /// Rises with a long, soft landing (Material's emphasized decelerate).
  static const Curve _openCurve = Cubic(0.05, 0.7, 0.1, 1.0);

  /// The close button / back: eases out of the way and speeds up as it goes, so it doesn't
  /// look like it was yanked.
  static const Curve _closeCurve = Cubic(0.3, 0.0, 0.8, 0.15);

  @override
  Duration get transitionDuration => _duration;

  @override
  Duration get reverseTransitionDuration => _duration * 0.72;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      const NowPlayingScreen();

  @override
  Widget buildTransitions(
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
      ) {
    if (_duration == Duration.zero) return child;
    final gesture = navigator?.userGestureInProgressNotifier;
    if (gesture == null) return _NowPlayingTransition(animation: _curved(animation), child: child);
    return ValueListenableBuilder<bool>(
      valueListenable: gesture,
      // While a finger is on it, the card follows the finger exactly (no curve), and the
      // throw that finishes the gesture keeps it that way until it lands.
      builder: (context, dragging, child) =>
          _NowPlayingTransition(animation: dragging ? animation : _curved(animation), child: child!),
      child: child,
    );
  }

  Animation<double> _curved(Animation<double> animation) =>
      CurvedAnimation(parent: animation, curve: _openCurve, reverseCurve: _closeCurve.flipped);

  // -------------------------------------------------------------------
  // Swipe down to close
  // -------------------------------------------------------------------

  bool _dragging = false;

  /// Height the card travels; drags are measured against it.
  double _travel(BuildContext context) => math.max(1.0, MediaQuery.sizeOf(context).height);

  void dragStart() {
    final navigator = this.navigator;
    if (_dragging || navigator == null || !isCurrent) return;
    _dragging = true;
    controller?.stop();
    navigator.didStartUserGesture();
  }

  void dragUpdate(BuildContext context, double deltaY) {
    final controller = this.controller;
    if (!_dragging || controller == null) return;
    controller.value = (controller.value - deltaY / _travel(context)).clamp(0.0, 1.0);
  }

  /// Let go: falls away when it was pulled far enough or thrown downward, settles back
  /// otherwise, carrying the throw's speed either way.
  void dragEnd(BuildContext context, double velocityY) {
    final controller = this.controller;
    final navigator = this.navigator;
    if (!_dragging || controller == null || navigator == null) return;
    _dragging = false;
    final travel = _travel(context);
    final speed = velocityY / travel; // fraction of the screen per second, + is down
    final close = speed > 0.9 || (speed > -0.5 && controller.value < 0.72);
    final remaining = close ? controller.value : 1 - controller.value;
    // Faster throws land sooner; never slower than a comfortable settle.
    final seconds = (remaining / math.max(speed.abs(), 1.6)).clamp(0.16, 0.42);
    final duration = Duration(milliseconds: (seconds * 1000).round());
    if (close) {
      navigator.pop();
      if (controller.isAnimating) {
        controller.animateBack(0, duration: duration, curve: Curves.easeOutCubic);
      }
    } else {
      controller.animateTo(1, duration: duration, curve: Curves.easeOutCubic);
    }
    if (controller.isAnimating) {
      void done(AnimationStatus status) {
        if (status == AnimationStatus.forward || status == AnimationStatus.reverse) return;
        controller.removeStatusListener(done);
        navigator.didStopUserGesture();
      }

      controller.addStatusListener(done);
    } else {
      navigator.didStopUserGesture();
    }
  }

  void dragCancel(BuildContext context) => dragEnd(context, 0);
}

/// The card: slides up from the bottom, top corners round off while it's moving, and the
/// page beneath dims in step with it.
class _NowPlayingTransition extends StatelessWidget {
  const _NowPlayingTransition({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value.clamp(0.0, 1.0);
        if (t >= 1) return child!;
        final height = MediaQuery.sizeOf(context).height;
        final radius = 28.0 * math.min(1.0, (1 - t) * 6);
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: 0.45 * t))),
            Transform.translate(
              offset: Offset(0, height * (1 - t)),
              child: ClipRRect(
                borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
                child: DecoratedBox(
                  // A soft shadow along the card's top edge while it moves.
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.center,
                      colors: [Colors.white.withValues(alpha: 0.05 * (1 - t)), Colors.transparent],
                    ),
                  ),
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
