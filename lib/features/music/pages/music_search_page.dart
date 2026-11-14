import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../utils/music_navigation.dart';
import '../../../widgets/music/track_row.dart';
import '../../../widgets/search_input_field.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import '../widgets/music_shelves.dart';

/// Atlas: music search. Results come back grouped: artists, albums, then songs. Only music
/// libraries are searched, so no movies or shows turn up here.
class MusicSearchPage extends StatefulWidget {
  const MusicSearchPage({super.key});

  @override
  State<MusicSearchPage> createState() => MusicSearchPageState();
}

class MusicSearchPageState extends State<MusicSearchPage> {
  final _controller = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'music.search');
  final _shelvesKey = GlobalKey<MusicShelvesState>();
  Timer? _debounce;
  String _query = '';
  MusicSearchResults? _results;
  bool _searching = false;
  int _generation = 0;

  /// Put the cursor in the search field (the tab was picked again, or TV landed here).
  void focusField() => _fieldFocus.requestFocus();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final query = _controller.text.trim();
    if (query == _query) return;
    _query = query;
    _debounce?.cancel();
    if (query.isEmpty) {
      _generation++;
      setState(() {
        _results = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => unawaited(_search(query)));
  }

  Future<void> _search(String query) async {
    final generation = ++_generation;
    setState(() => _searching = true);
    try {
      final results = await MusicCatalog.of(context).search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final focus = MusicShellFocus.maybeOf(context);
    return MusicPage(
      title: MusicStrings.search,
      children: [
        Padding(
          padding: MusicPage.padding(context).add(const EdgeInsets.only(bottom: 8)),
          child: SearchInputField(
            controller: _controller,
            focusNode: _fieldFocus,
            hintText: MusicStrings.searchHint,
            debugLabel: 'music.search',
            onNavigateLeft: focus?.focusRail,
            onNavigateDown: () => _shelvesKey.currentState?.focusFirst(),
          ),
        ),
        if (_searching && results == null)
          const MusicPagePlaceholder()
        else if (results != null && results.isEmpty)
          const MusicPagePlaceholder(message: MusicStrings.noResults)
        else if (results != null) ...[
            MusicShelves(
              key: _shelvesKey,
              onNavigateUp: _fieldFocus.requestFocus,
              onNavigateToSidebar: focus?.focusRail,
              shelves: [
                MusicShelf(id: 'search-artists', title: MusicStrings.artists, icon: Symbols.person_rounded, items: results.artists),
                MusicShelf(id: 'search-albums', title: MusicStrings.albums, icon: Symbols.album_rounded, items: results.albums),
              ],
            ),
            if (results.songs.isNotEmpty) ...[
              const MusicSectionTitle(MusicStrings.songs),
              Padding(
                padding: MusicPage.padding(context),
                child: Column(
                  children: [
                    for (final (index, track) in results.songs.take(25).indexed)
                      TrackRow(
                        item: track,
                        showArtist: true,
                        showTrackNumber: false,
                        isFirst: index == 0,
                        isLast: index == results.songs.take(25).length - 1,
                        onTap: () => unawaited(playTrackWithAlbumContext(context, track)),
                      ),
                  ],
                ),
              ),
            ],
          ],
      ],
    );
  }
}
