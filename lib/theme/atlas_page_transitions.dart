import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Atlas: how pages come and go everywhere outside iOS (which keeps its native slide and
/// swipe-back). The new page drifts in from the side while it fades up from slightly smaller,
/// and the page it covers eases the other way and dims, so it reads as one surface moving
/// over another rather than a cut. Going back plays it in reverse.
class AtlasPageTransitionsBuilder extends PageTransitionsBuilder {
  const AtlasPageTransitionsBuilder();

  /// A long, soft landing (Material's emphasized decelerate) in, quicker out.
  static const Curve _in = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve _out = Cubic(0.3, 0.0, 0.8, 0.15);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
      ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final incoming = CurvedAnimation(parent: animation, curve: _in, reverseCurve: _out.flipped);
    final covered = CurvedAnimation(parent: secondaryAnimation, curve: _in, reverseCurve: _out.flipped);
    final rtl = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    return AnimatedBuilder(
      animation: Listenable.merge([incoming, covered]),
      child: child,
      builder: (context, child) {
        final t = incoming.value;
        final c = covered.value;
        // In: from 6% over and 96% size, fading up over the first half.
        final dx = (1 - t) * 0.06 * rtl - c * 0.04 * rtl;
        final scale = 0.96 + 0.04 * t - 0.02 * c;
        final opacity = (t * 2).clamp(0.0, 1.0);
        Widget page = FractionalTranslation(
          translation: Offset(dx, 0),
          child: Transform.scale(scale: scale, child: child),
        );
        if (opacity < 1) page = Opacity(opacity: opacity, child: page);
        if (c > 0) {
          // The covered page dims a little as it slips back.
          page = ColorFiltered(
            colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.18 * c), BlendMode.srcATop),
            child: page,
          );
        }
        return page;
      },
    );
  }
}

/// The transitions for every platform: iOS and macOS keep Cupertino's (with swipe back), the
/// rest use [AtlasPageTransitionsBuilder].
const atlasPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: AtlasPageTransitionsBuilder(),
    TargetPlatform.fuchsia: AtlasPageTransitionsBuilder(),
    TargetPlatform.linux: AtlasPageTransitionsBuilder(),
    TargetPlatform.windows: AtlasPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
  },
);
