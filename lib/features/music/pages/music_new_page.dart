import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../media/artist_discography.dart';
import '../../../media/media_item.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import '../widgets/music_shelves.dart';

/// Atlas: music mode's New page: the newest releases in the library by release date, split into
/// albums and singles/EPs, plus what was added most recently.
class MusicNewPage extends StatefulWidget {
  const MusicNewPage({super.key});

  @override
  State<MusicNewPage> createState() => _MusicNewPageState();
}

class _MusicNewPageState extends State<MusicNewPage> {
  List<MusicShelf>? _shelves;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final catalog = MusicCatalog.of(context);
    try {
      final results = await Future.wait([catalog.newReleases(limit: 60), catalog.recentlyAddedAlbums(limit: 30)]);
      if (!mounted) return;
      final releases = results[0];
      final singles = <MediaItem>[];
      final albums = <MediaItem>[];
      for (final release in releases) {
        (classifyReleaseByShape(release) == DiscographyGroupKind.singlesAndEps ? singles : albums).add(release);
      }
      setState(() {
        _failed = false;
        _shelves = [
          MusicShelf(id: 'new-albums', title: MusicStrings.newReleases, icon: Symbols.album_rounded, items: albums),
          MusicShelf(id: 'new-singles', title: MusicStrings.newSinglesAndEps, icon: Symbols.music_note_rounded, items: singles),
          MusicShelf(id: 'recently-added', title: MusicStrings.recentlyAdded, icon: Symbols.new_releases_rounded, items: results[1]),
        ];
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shelves = _shelves;
    return MusicPage(
      title: MusicStrings.newTab,
      onRefresh: _load,
      children: [
        if (shelves == null)
          MusicPagePlaceholder(message: _failed ? MusicStrings.loadFailed : null)
        else if (shelves.every((shelf) => shelf.items.isEmpty))
          const MusicPagePlaceholder(message: MusicStrings.nothingYet)
        else
          MusicShelves(shelves: shelves, onNavigateToSidebar: MusicShellFocus.maybeOf(context)?.focusRail),
      ],
    );
  }
}
