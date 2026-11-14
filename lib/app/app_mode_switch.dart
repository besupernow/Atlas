import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../providers/libraries_provider.dart';
import 'app_mode.dart';

/// Atlas: what the video/music switch shows and whether it shows at all. The video and music
/// shells each place it themselves (top bar on phone and desktop, sidebar on TV).
abstract final class AppModeSwitch {
  /// Only when the servers have both movie/TV and music libraries. Rebuilds the caller when
  /// libraries change.
  static bool available(BuildContext context) {
    final LibrariesProvider libraries;
    try {
      libraries = context.watch<LibrariesProvider>();
    } on ProviderNotFoundException {
      return false;
    }
    return libraries.hasVideoLibraries && libraries.hasMusicLibraries;
  }

  /// A music note in video mode (go to music), a film in music mode (go to movies and TV).
  static IconData icon(AppMode current) =>
      current == AppMode.video ? Symbols.music_note_rounded : Symbols.movie_rounded;

  static String label(AppMode current) => current == AppMode.video ? 'Music' : 'Movies & TV';

  static void toggle() => AppModeController.instance.toggle();
}
