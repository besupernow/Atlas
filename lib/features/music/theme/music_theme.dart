import 'package:flutter/material.dart';

/// Atlas: music mode's look. The selected app theme as it is (surfaces, type, shapes and the
/// accent the person picked), with progress and sliders following that accent.
abstract final class MusicTheme {
  static ThemeData of(ThemeData base) {
    final accent = base.colorScheme.primary;
    return base.copyWith(
      progressIndicatorTheme: base.progressIndicatorTheme.copyWith(color: accent),
      sliderTheme: base.sliderTheme.copyWith(activeTrackColor: accent, thumbColor: accent),
    );
  }
}

/// Colors for music's own artwork (mix covers, genre and station tiles), all made from the
/// theme's accent so a different accent recolors the whole of music mode.
abstract final class MusicColors {
  /// A two-stop gradient in the accent's family, turned [shift] degrees around the color wheel
  /// (small shifts keep it recognisably the accent).
  static List<Color> gradient(Color accent, {double shift = 0}) {
    final base = HSLColor.fromColor(accent);
    final saturation = base.saturation.clamp(0.45, 0.85);
    final start = HSLColor.fromAHSL(1, (base.hue + shift) % 360, saturation, 0.52);
    final end = HSLColor.fromAHSL(1, (base.hue + shift + 28) % 360, saturation, 0.34);
    return [start.toColor(), end.toColor()];
  }

  /// A steady gradient per name (a genre, a station), in the accent's family.
  static List<Color> forName(Color accent, String name) {
    final hash = name.toLowerCase().codeUnits.fold<int>(7, (hash, unit) => (hash * 31 + unit) & 0x7fffffff);
    return gradient(accent, shift: (hash % 100) - 50.0);
  }

  /// The darker band under a card's art.
  static Color band(List<Color> colors) => Color.lerp(colors.last, Colors.black, 0.25)!;
}
