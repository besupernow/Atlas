import 'package:flutter/material.dart';

import 'web_theme_color_stub.dart' if (dart.library.js_interop) 'web_theme_color_web.dart';

/// On web, keeps the page background, the loading splash and the browser's
/// theme-color (mobile status/address bars) in step with the app's theme.
/// Does nothing on other platforms.
class WebThemeColorSync extends StatelessWidget {
  const WebThemeColorSync({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    applyWebThemeColor(theme.scaffoldBackgroundColor, isDark: theme.brightness == Brightness.dark);
    return child;
  }
}
