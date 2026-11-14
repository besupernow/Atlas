import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../media/media_kind.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import '../widgets/music_shelves.dart';
import 'music_lists.dart';

/// Atlas: music mode's Library: Playlists, Artists, Albums, Songs and Genres, then the albums
/// added most recently.
class MusicLibraryPage extends StatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  final _shelvesKey = GlobalKey<MusicShelvesState>();
  MusicShelf? _recent;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final items = await MusicCatalog.of(context).recentlyAddedAlbums(limit: 30);
    if (!mounted) return;
    setState(() {
      _recent = MusicShelf(id: 'library-recent', title: MusicStrings.recentlyAdded, icon: Symbols.new_releases_rounded, items: items);
    });
  }

  void _open(Widget page) {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)));
  }

  @override
  Widget build(BuildContext context) {
    final recent = _recent;
    final entries = <(IconData, String, Widget Function())>[
      (Symbols.queue_music_rounded, MusicStrings.playlists, () => const MusicPlaylistsPage()),
      (Symbols.artist_rounded, MusicStrings.artists, () => const MusicItemGridPage(kind: MediaKind.artist, title: MusicStrings.artists)),
      (Symbols.album_rounded, MusicStrings.albums, () => const MusicItemGridPage(kind: MediaKind.album, title: MusicStrings.albums)),
      (Symbols.music_note_rounded, MusicStrings.songs, () => const MusicSongsPage()),
      (Symbols.category_rounded, MusicStrings.genres, () => const MusicGenresPage()),
    ];
    final focus = MusicShellFocus.maybeOf(context);
    return MusicPage(
      title: MusicStrings.library,
      onRefresh: _load,
      children: [
        for (final (icon, label, page) in entries)
          Padding(
            padding: MusicPage.padding(context),
            child: FocusableListTile(
              leading: AppIcon(icon, fill: 1, color: Theme.of(context).colorScheme.primary),
              title: Text(label, style: Theme.of(context).textTheme.titleMedium),
              trailing: const AppIcon(Symbols.chevron_right_rounded),
              onTap: () => _open(page()),
            ),
          ),
        if (recent != null)
          MusicShelves(key: _shelvesKey, shelves: [recent], onNavigateToSidebar: focus?.focusRail),
      ],
    );
  }
}
