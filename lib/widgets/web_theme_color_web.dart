import 'dart:ui' show Color;

import 'package:web/web.dart' as web;

String? _last;

void applyWebThemeColor(Color color, {required bool isDark}) {
  final hex = '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  if (hex == _last) return;
  _last = hex;
  try {
    // index.html paints html/body and the splash with var(--atlas-bg).
    web.document.documentElement?.setAttribute('style', '--atlas-bg:$hex');
    web.document.querySelector('meta[name="theme-color"]')?.setAttribute('content', hex);
    web.document.querySelector('meta[name="color-scheme"]')?.setAttribute('content', isDark ? 'dark' : 'light');
    // Remembered so the next visit's splash starts in the right color.
    web.window.localStorage.setItem('atlas_bg', hex);
  } catch (_) {}
}
