import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Atlas: the one frosted look music mode uses everywhere (rows, panels, the mini player,
/// queue entries): a see-through surface with a faint wash of the accent color and a hairline
/// light edge, so everything sits on the blurred art the same way.
abstract final class MusicGlass {
  /// The fill. [strength] above 1 makes it more solid (things floating over busy content,
  /// like the mini player); below 1 lighter.
  static Color tint(BuildContext context, {double strength = 1}) {
    final scheme = Theme.of(context).colorScheme;
    return Color.alphaBlend(
      scheme.primary.withValues(alpha: (0.07 * strength).clamp(0.0, 1.0)),
      scheme.surface.withValues(alpha: (0.32 * strength).clamp(0.0, 1.0)),
    );
  }

  /// The hairline edge that catches the light.
  static Color edge(BuildContext context) => Colors.white.withValues(alpha: 0.07);

  /// The fill used while a row is the one playing: a little more of the accent.
  static Color currentTint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Color.alphaBlend(scheme.primary.withValues(alpha: 0.16), scheme.surface.withValues(alpha: 0.36));
  }
}

/// A frosted surface: blurs what's behind it and lays [MusicGlass.tint] over it.
class MusicGlassSurface extends StatelessWidget {
  const MusicGlassSurface({
    super.key,
    required this.child,
    this.radius = 16,
    this.strength = 1,
    this.blur = 24,
  });

  final Widget child;
  final double radius;
  final double strength;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: MusicGlass.tint(context, strength: strength),
        borderRadius: shape,
        border: Border.all(color: MusicGlass.edge(context)),
      ),
      child: child,
    );
    if (blur > 0) {
      surface = BackdropFilter(filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: surface);
    }
    return ClipRRect(borderRadius: shape, child: surface);
  }
}
