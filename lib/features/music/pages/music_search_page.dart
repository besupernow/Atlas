import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../utils/music_navigation.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/search_input_field.dart';
import '../discover/discover_feed.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import '../discover/music_previews.dart';
import '../discover/music_search.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_item_menu.dart';
import '../widgets/music_page.dart';

/// Atlas: music search, across the server and everything out there. Typos are fine and popular
/// things come first (see [MusicSearch]). A top result, then artists, albums and songs; ours
/// play, the rest can be previewed and requested right from the results.
class MusicSearchPage extends StatefulWidget {
  const MusicSearchPage({super.key});

  @override
  State<MusicSearchPage> createState() => MusicSearchPageState();
}

class MusicSearchPageState extends State<MusicSearchPage> {
  final _controller = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'music.search');
  Timer? _debounce;
  String _query = '';
  MusicSearchOutcome? _results;
  bool _searching = false;

  /// Apple Music's two scopes: everything, or just what's on the server.
  bool _libraryOnly = false;
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
    if (query.length < 2) {
      _generation++;
      setState(() {
        _results = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => unawaited(_search(query)));
  }

  Future<void> _search(String query) async {
    final generation = ++_generation;
    setState(() => _searching = true);
    try {
      final search = MusicSearch(MusicDiscovery.of(context));
      // What earlier searches already know shows right away; the full answer replaces it.
      if (!_libraryOnly) {
        final instant = search.instant(query);
        if (!instant.isEmpty) setState(() => _results = instant);
      }
      final results = _libraryOnly ? await search.searchLibrary(query) : await search.search(query);
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
    final top = results?.top;
    final topSong = results?.topSong;
    return MusicPage(
      title: MusicStrings.search,
      children: [
        Padding(
          padding: MusicPage.padding(context).add(const EdgeInsets.only(bottom: 8)),
          child: SearchInputField(
            controller: _controller,
            focusNode: _fieldFocus,
            hintText: MusicStrings.searchHintEverywhere,
            debugLabel: 'music.search',
            onNavigateLeft: focus?.focusRail,
          ),
        ),
        Padding(
          padding: MusicPage.padding(context).add(const EdgeInsets.only(bottom: 8)),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text(MusicStrings.everywhere)),
              ButtonSegment(value: true, label: Text(MusicStrings.library)),
            ],
            selected: {_libraryOnly},
            onSelectionChanged: (selection) {
              setState(() => _libraryOnly = selection.first);
              if (_query.length >= 2) unawaited(_search(_query));
            },
          ),
        ),
        if (_searching)
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: LinearProgressIndicator(minHeight: 2)),
        if (results == null && !_searching)
          const MusicPagePlaceholder(message: MusicStrings.searchEmptyHint)
        else if (results != null && results.isEmpty && !_searching)
          const MusicPagePlaceholder(message: MusicStrings.noResults)
        else if (results != null) ...[
          if (top != null) _TopResult(item: top) else if (topSong != null) _TopSongResult(song: topSong),
          MusicFeedShelf(
            title: MusicStrings.artists,
            items: results.artists.where((item) => item.key != top?.key).toList(),
            onNavigateToSidebar: focus?.focusRail,
          ),
          if (results.songs.isNotEmpty) ...[
            Padding(
              padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 22, bottom: 6)),
              child: const MusicSectionHeader(title: MusicStrings.songs),
            ),
            Padding(
              padding: MusicPage.padding(context),
              child: Column(
                children: [
                  for (final song in results.songs)
                    if (song.key != topSong?.key) _SongResult(song: song),
                ],
              ),
            ),
          ],
          MusicFeedShelf(
            title: MusicStrings.albums,
            items: results.albums.where((item) => item.key != top?.key).toList(),
            onNavigateToSidebar: focus?.focusRail,
          ),
        ],
      ],
    );
  }
}

/// The best match, big: art, name, what it is, and the obvious action.
class _TopResult extends StatelessWidget {
  const _TopResult({required this.item});

  final MusicFeedItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (String title, String kind) = switch (item) {
      ServerFeedItem(:final item) => (item.title ?? '', item.albumArtistTitle ?? MusicStrings.onServer),
      ExternalAlbumItem(:final album) => (album.title, [album.type ?? MusicStrings.albumLabel, album.artistName].join(' · ')),
      ExternalArtistItem(:final artist) => (artist.name, MusicStrings.artistLabel),
    };
    void open() => unawaited(openFeedItem(context, item));
    return Padding(
      padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 14)),
      child: FocusableWrapper(
        borderRadius: 22,
        onSelect: open,
        onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: open,
            onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
            onSecondaryTapUp: (details) =>
                unawaited(MusicItemMenu.show(context, item, position: details.globalPosition)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  MusicArt(item: item, size: 104, radius: 14),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          MusicStrings.topResult.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.5),
                        ),
                        Text(
                          kind,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (item case ExternalAlbumItem(:final album)) ...[
                    const SizedBox(width: 8),
                    RequestButton(album: album, compact: true),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A song in the results. Ours: tap plays it. Not ours: tap opens its release, the button
/// previews it, the menu requests it.
class _SongResult extends StatelessWidget {
  const _SongResult({required this.song});

  final SearchSong song;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final server = song.server;
    final external = song.external;
    final MusicFeedItem item = server != null ? ServerFeedItem(server) : ExternalAlbumItem(external!.album);

    void open() {
      if (server != null) {
        unawaited(MusicPreviewPlayer.instance.cancel().then((_) {
          if (context.mounted) unawaited(playTrackWithAlbumContext(context, server));
        }));
      } else {
        unawaited(openFeedItem(context, item));
      }
    }

    final preview = external?.previewUrl;
    final subtitle = [
      song.artist,
      if (server == null) external?.album.title else server.albumTitle,
    ].whereType<String>().where((part) => part.isNotEmpty).join(' · ');

    return FocusableWrapper(
      borderRadius: 12,
      onSelect: open,
      onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(12),
        onTap: open,
        onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
        onSecondaryTapUp: (details) => unawaited(MusicItemMenu.show(context, item, position: details.globalPosition)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Stack(
                children: [
                  MusicArt(item: item, size: 52, radius: 8),
                  if (server == null)
                    const Positioned(right: 2, bottom: 2, child: AppIcon(Symbols.cloud_rounded, size: 14, color: Colors.white, fill: 1.0)),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (server != null)
                IconButton(
                  tooltip: MusicStrings.play,
                  onPressed: open,
                  icon: AppIcon(Symbols.play_arrow_rounded, color: scheme.primary, fill: 1.0),
                )
              else if (preview != null && external != null && MusicPreviews.supported)
                ListenableBuilder(
                  listenable: MusicPreviewPlayer.instance,
                  builder: (context, _) {
                    final player = MusicPreviewPlayer.instance;
                    final playing = player.isPlaying(external.previewKey);
                    return IconButton(
                      tooltip: MusicStrings.preview,
                      onPressed: () => unawaited(
                        player.toggle(context, external.previewKey, [PreviewClip(title: external.title, url: preview)]),
                      ),
                      icon: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (playing)
                            SizedBox(
                              width: 30,
                              height: 30,
                              child: CircularProgressIndicator(value: player.loading ? null : player.progress, strokeWidth: 2),
                            ),
                          AppIcon(playing ? Symbols.stop_rounded : Symbols.play_arrow_rounded, color: scheme.primary, fill: 1.0),
                        ],
                      ),
                    );
                  },
                ),
              IconButton(
                tooltip: MusicStrings.more,
                onPressed: () => unawaited(MusicItemMenu.show(context, item)),
                icon: const AppIcon(Symbols.more_horiz_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The top result when it's a song: big, with play (ours) or preview and request (not ours).
class _TopSongResult extends StatelessWidget {
  const _TopSongResult({required this.song});

  final SearchSong song;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final server = song.server;
    final external = song.external;
    final MusicFeedItem item = server != null ? ServerFeedItem(server) : ExternalAlbumItem(external!.album);
    void play() {
      if (server != null) {
        unawaited(MusicPreviewPlayer.instance.cancel().then((_) {
          if (context.mounted) unawaited(playTrackWithAlbumContext(context, server));
        }));
      } else {
        unawaited(openFeedItem(context, item));
      }
    }

    final preview = external?.previewUrl;
    return Padding(
      padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 14)),
      child: FocusableWrapper(
        borderRadius: 22,
        onSelect: play,
        onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: play,
            onLongPress: () => unawaited(MusicItemMenu.show(context, item)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  MusicArt(item: item, size: 96, radius: 14),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          MusicStrings.topResult.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          song.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.5),
                        ),
                        Text(
                          '${MusicStrings.songLabel} · ${song.artist}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (server != null)
                              FilledButton.icon(
                                onPressed: play,
                                icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1.0),
                                label: const Text(MusicStrings.play),
                              )
                            else ...[
                              if (preview != null && external != null && MusicPreviews.supported)
                                ListenableBuilder(
                                  listenable: MusicPreviewPlayer.instance,
                                  builder: (context, _) {
                                    final playing = MusicPreviewPlayer.instance.isPlaying(external.previewKey);
                                    return FilledButton.tonalIcon(
                                      onPressed: () => unawaited(
                                        MusicPreviewPlayer.instance.toggle(context, external.previewKey, [
                                          PreviewClip(title: external.title, url: preview),
                                        ]),
                                      ),
                                      icon: AppIcon(playing ? Symbols.stop_rounded : Symbols.play_arrow_rounded, fill: 1.0),
                                      label: Text(playing ? MusicStrings.stop : MusicStrings.preview),
                                    );
                                  },
                                ),
                              if (external != null) RequestButton(album: external.album, compact: true),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

