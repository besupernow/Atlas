import 'package:flutter/material.dart';

/// Atlas: music mode's look. Same surfaces, type and shapes as the selected app theme (so light,
/// dark and the user's theme carry over), with music's own accent in place of the theme's.
abstract final class MusicTheme {
  /// A warm pink-red, in the spirit of Apple Music.
  static const accentLight = Color(0xFFE5293F);
  static const accentDark = Color(0xFFFF4D67);

  static ThemeData of(ThemeData base) {
    final dark = base.brightness == Brightness.dark;
    final accent = dark ? accentDark : accentLight;
    final scheme = base.colorScheme.copyWith(
      primary: accent,
      onPrimary: Colors.white,
      secondary: accent,
      onSecondary: Colors.white,
      primaryContainer: Color.alphaBlend(accent.withValues(alpha: dark ? 0.28 : 0.16), base.colorScheme.surface),
      onPrimaryContainer: dark ? Colors.white : const Color(0xFF3A0711),
      secondaryContainer: Color.alphaBlend(accent.withValues(alpha: dark ? 0.22 : 0.12), base.colorScheme.surface),
      onSecondaryContainer: dark ? Colors.white : const Color(0xFF3A0711),
    );
    return base.copyWith(
      colorScheme: scheme,
      progressIndicatorTheme: base.progressIndicatorTheme.copyWith(color: accent),
      sliderTheme: base.sliderTheme.copyWith(activeTrackColor: accent, thumbColor: accent),
    );
  }
}
