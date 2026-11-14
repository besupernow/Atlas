import 'package:flutter/widgets.dart';

import '../media/media_item.dart';

/// Atlas: inside music mode, artist and album pages open inside the current music tab (so the
/// tab bar and mini player stay put, like Apple Music) instead of over the whole app.
///
/// Music mode's tabs wrap their navigators in this. The shared navigation helpers
/// (`navigateToArtist`, `navigateToAlbum`) check for it; outside music mode they behave as
/// before. [artistPage] and [albumPage] let music mode use its own pages.
class MusicDetailScope extends InheritedWidget {
  const MusicDetailScope({super.key, required this.artistPage, this.albumPage, required super.child});

  final Widget Function(MediaItem artist) artistPage;

  /// Music mode's own page for albums, EPs and singles.
  final Widget Function(MediaItem album)? albumPage;

  static MusicDetailScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MusicDetailScope>();

  @override
  bool updateShouldNotify(MusicDetailScope oldWidget) => false;
}

/// Atlas: lets screens that sit above music mode (Now Playing) open an artist or album page in
/// music mode's current tab. Music mode sets [open] while it's built; null otherwise.
abstract final class MusicModeLinks {
  static void Function(MediaItem item)? open;
}
