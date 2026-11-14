import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../media/media_item.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../widgets/app_icon.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import '../widgets/music_shelves.dart';

/// Atlas: music mode's Radio: "Your Station" (a mix from the songs you play most), a station
/// per artist, and genre stations. Stations play songs already in the library; the
/// recommendation sidecar will add music you don't have yet.
class MusicRadioPage extends StatefulWidget {
  const MusicRadioPage({super.key});

  @override
  State<MusicRadioPage> createState() => _MusicRadioPageState();
}

class _MusicRadioPageState extends State<MusicRadioPage> {
  final _stationFocus = FocusNode(debugLabel: 'music_your_station');
  final _shelvesKey = GlobalKey<MusicShelvesState>();
  final List<FocusNode> _genreFocus = [];
  List<MediaItem>? _artists;
  List<MusicGenre> _genres = const [];
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _stationFocus.dispose();
    for (final node in _genreFocus) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final catalog = MusicCatalog.of(context);
    try {
      final results = await Future.wait([catalog.stationArtists(limit: 16), catalog.genres()]);
      if (!mounted) return;
      final genres = results[1] as List<MusicGenre>;
      while (_genreFocus.length < genres.length) {
        _genreFocus.add(FocusNode(debugLabel: 'music_genre_station'));
      }
      setState(() {
        _failed = false;
        _artists = results[0] as List<MediaItem>;
        _genres = genres;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _playYourStation() async {
    final seed = await MusicCatalog.of(context).stationSeed();
    if (seed == null || !mounted) return;
    await playInstantMix(context, seed);
  }

  Future<void> _playGenre(MusicGenre genre) async {
    final catalog = MusicCatalog.of(context);
    await playFetchedTracks(
      context,
      fetch: () => catalog.genreTracks(genre),
      playContext: MusicPlayContext(title: genre.title, kind: MusicPlayContextKind.mix),
    );
  }

  @override
  Widget build(BuildContext context) {
    final artists = _artists;
    final focus = MusicShellFocus.maybeOf(context);
    final theme = Theme.of(context);
    final isTV = PlatformDetector.isTV();
    return MusicPage(
      title: MusicStrings.radio,
      onRefresh: _load,
      children: [
        Padding(
          padding: MusicPage.padding(context),
          child: FocusableWrapper(
            focusNode: _stationFocus,
            borderRadius: 20,
            onSelect: () => unawaited(_playYourStation()),
            onNavigateLeft: focus?.focusRail,
            onNavigateDown: () => _shelvesKey.currentState?.focusFirst(),
            child: _StationCard(
              title: MusicStrings.yourStation,
              subtitle: MusicStrings.yourStationSubtitle,
              icon: Symbols.radio_rounded,
              colors: [theme.colorScheme.primary, Color.lerp(theme.colorScheme.primary, Colors.black, 0.45)!],
              height: isTV ? 200 : 160,
              onTap: () => unawaited(_playYourStation()),
            ),
          ),
        ),
        if (artists == null)
          MusicPagePlaceholder(message: _failed ? MusicStrings.loadFailed : null)
        else ...[
          MusicShelves(
            key: _shelvesKey,
            shelves: [
              MusicShelf(
                id: 'artist-stations',
                title: MusicStrings.artistStations,
                icon: Symbols.artist_rounded,
                items: artists,
                onItemTap: (artist) => unawaited(playInstantMix(context, artist)),
              ),
            ],
            onNavigateUp: _stationFocus.requestFocus,
            onNavigateDown: () {
              if (_genreFocus.isNotEmpty) _genreFocus.first.requestFocus();
            },
            onNavigateToSidebar: focus?.focusRail,
          ),
          if (_genres.isNotEmpty) ...[
            const MusicSectionTitle(MusicStrings.genreStations),
            SizedBox(
              height: isTV ? 120 : 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: MusicPage.padding(context),
                itemCount: _genres.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final genre = _genres[index];
                  return FocusableWrapper(
                    focusNode: _genreFocus[index],
                    borderRadius: 16,
                    onSelect: () => unawaited(_playGenre(genre)),
                    onNavigateLeft: index == 0 ? focus?.focusRail : () => _genreFocus[index - 1].requestFocus(),
                    onNavigateRight: index < _genres.length - 1 ? () => _genreFocus[index + 1].requestFocus() : null,
                    onNavigateUp: () {
                      if (!(_shelvesKey.currentState?.focusLast() ?? false)) _stationFocus.requestFocus();
                    },
                    child: _StationCard(
                      title: genre.title,
                      icon: Symbols.graphic_eq_rounded,
                      colors: _genreColors(genre.title),
                      width: isTV ? 240 : 180,
                      onTap: () => unawaited(_playGenre(genre)),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ],
    );
  }

  /// A steady pair of colors per genre name, so each genre always looks the same.
  static List<Color> _genreColors(String name) {
    final hue = (name.toLowerCase().codeUnits.fold<int>(7, (hash, unit) => (hash * 31 + unit) & 0x7fffffff) % 360)
        .toDouble();
    return [
      HSLColor.fromAHSL(1, hue, 0.55, 0.45).toColor(),
      HSLColor.fromAHSL(1, (hue + 40) % 360, 0.6, 0.28).toColor(),
    ];
  }
}

class _StationCard extends StatelessWidget {
  const _StationCard({
    required this.title,
    required this.icon,
    required this.colors,
    required this.onTap,
    this.subtitle,
    this.height,
    this.width,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;
  final double? height;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      height: height,
      width: width,
      child: Material(
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
            padding: const EdgeInsets.all(16),
            child: Stack(
              children: [
                Positioned(right: -8, bottom: -12, child: AppIcon(icon, size: 96, color: Colors.white.withValues(alpha: 0.18))),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                    ),
                    if (subtitle != null)
                      Text(subtitle!, style: textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
