import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../utils/music_navigation.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import '../widgets/music_shelves.dart';

/// Atlas: music mode's Home: what you've been playing, what's new in the library, your
/// favorites, and stations built from the artists you play most.
class MusicHomePage extends StatefulWidget {
  const MusicHomePage({super.key});

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

class _MusicHomePageState extends State<MusicHomePage> {
  final _shelvesKey = GlobalKey<MusicShelvesState>();
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
      final results = await Future.wait([
        catalog.recentlyPlayed(),
        catalog.recentlyAddedAlbums(),
        catalog.mostPlayed(),
        catalog.favoriteAlbums(),
        catalog.stationArtists(limit: 10),
      ]);
      if (!mounted) return;
      setState(() {
        _failed = false;
        _shelves = [
          MusicShelf(id: 'recently-played', title: MusicStrings.recentlyPlayed, icon: Symbols.history_rounded, items: results[0]),
          MusicShelf(id: 'recently-added', title: MusicStrings.recentlyAdded, icon: Symbols.new_releases_rounded, items: results[1]),
          MusicShelf(
            id: 'stations',
            title: MusicStrings.mixes,
            icon: Symbols.radio_rounded,
            items: results[4],
            onItemTap: (artist) => unawaited(playInstantMix(context, artist)),
          ),
          MusicShelf(id: 'most-played', title: MusicStrings.mostPlayed, icon: Symbols.trending_up_rounded, items: results[2]),
          MusicShelf(id: 'favorites', title: MusicStrings.favorites, icon: Symbols.favorite_rounded, items: results[3]),
        ];
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shelves = _shelves;
    final focus = MusicShellFocus.maybeOf(context);
    return MusicPage(
      title: MusicStrings.home,
      onRefresh: _load,
      children: [
        if (shelves == null)
          MusicPagePlaceholder(message: _failed ? MusicStrings.loadFailed : null)
        else if (shelves.every((shelf) => shelf.items.isEmpty))
          const MusicPagePlaceholder(message: MusicStrings.nothingYet)
        else
          MusicShelves(key: _shelvesKey, shelves: shelves, onNavigateToSidebar: focus?.focusRail),
      ],
    );
  }
}
