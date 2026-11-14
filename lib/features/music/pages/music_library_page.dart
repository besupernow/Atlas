import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../media/media_kind.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../data/music_catalog.dart';
import '../discover/discover_feed.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import 'music_lists.dart';

/// Atlas: music mode's Library, like Apple Music's: only what you've saved. Your playlists,
/// and the artists, albums and songs you've favorited (the heart). Everything else on the
/// server lives in Home, New, Radio and Search.
class MusicLibraryPage extends StatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  List<MusicFeedItem>? _saved;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final items = await MusicCatalog.of(context).favoriteAlbums(limit: 30).catchError((Object _) => const []);
    if (!mounted) return;
    setState(() => _saved = MusicDiscovery.server(items));
  }

  void _open(Widget page) {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = _saved;
    final entries = <(IconData, String, Widget Function())>[
      (Symbols.queue_music_rounded, MusicStrings.playlists, () => const MusicPlaylistsPage()),
      (
        Symbols.artist_rounded,
        MusicStrings.artists,
        () => const MusicItemGridPage(kind: MediaKind.artist, title: MusicStrings.artists, favoritesOnly: true),
      ),
      (
        Symbols.album_rounded,
        MusicStrings.albums,
        () => const MusicItemGridPage(kind: MediaKind.album, title: MusicStrings.albums, favoritesOnly: true),
      ),
      (Symbols.music_note_rounded, MusicStrings.songs, () => const MusicSongsPage(favoritesOnly: true)),
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
              leading: AppIcon(icon, fill: 1.0, color: theme.colorScheme.primary),
              title: Text(label, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              trailing: const AppIcon(Symbols.chevron_right_rounded),
              onTap: () => _open(page()),
            ),
          ),
        if (saved == null)
          const MusicPagePlaceholder()
        else if (saved.isEmpty)
          Padding(
            padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 32)),
            child: Column(
              children: [
                AppIcon(Symbols.favorite_rounded, size: 48, color: theme.colorScheme.primary, fill: 1.0),
                const SizedBox(height: 12),
                Text(
                  MusicStrings.libraryEmpty,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          )
        else
          MusicFeedShelf(
            title: MusicStrings.recentlyFavorited,
            items: saved,
            large: true,
            onNavigateToSidebar: focus?.focusRail,
          ),
      ],
    );
  }
}
