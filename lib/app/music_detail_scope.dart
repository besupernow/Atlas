import 'package:flutter/widgets.dart';

import '../media/media_item.dart';

/// Atlas: inside music mode, artist and album pages open inside the current music tab (so the
/// tab bar and mini player stay put, like Apple Music) instead of over the whole app.
///
/// Music mode's tabs wrap their navigators in this. The shared navigation helpers
/// (`navigateToArtist`, `navigateToAlbum`) check for it; outside music mode they behave as
/// before. [artistPage] lets music mode use its own artist page.
class MusicDetailScope extends InheritedWidget {
  const MusicDetailScope({super.key, required this.artistPage, required super.child});

  final Widget Function(MediaItem artist) artistPage;

  static MusicDetailScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MusicDetailScope>();

  @override
  bool updateShouldNotify(MusicDetailScope oldWidget) => false;
}
