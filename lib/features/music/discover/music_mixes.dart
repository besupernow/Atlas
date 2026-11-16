import 'dart:math';

import 'package:flutter/painting.dart';

import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';
import '../theme/music_theme.dart';

/// Atlas: a mix made from the server for this person, like Apple Music's "Made for You" mixes.
/// Built fresh on every Home load from what they favorite, play and haven't heard yet.
/// (AudioMuse-AI will add mood mixes like Chill and Get Up later.)
class MusicMix {
  const MusicMix({required this.id, required this.title, required this.hueShift, required this.tracks});

  final String id;

  /// Two lines on the art: "New Music" / "Mix".
  final ({String top, String bottom}) title;
  /// How far from the theme's accent this mix's colors turn (each mix its own shade of it).
  final double hueShift;
  final List<MediaItem> tracks;

  /// The cover gradient, made from the theme's [accent].
  List<Color> colorsFor(Color accent) => MusicColors.gradient(accent, shift: hueShift);

  /// The darker band under the cover.
  Color bandColorFor(Color accent) => MusicColors.band(colorsFor(accent));

  String get fullTitle => '${title.top} ${title.bottom}';

  /// "Artist, Artist, Artist and more": the line under the art.
  String get artistLine {
    final names = <String>[];
    for (final track in tracks) {
      final name = track.trackArtistTitle ?? track.albumArtistTitle;
      if (name != null && name.isNotEmpty && !names.contains(name)) names.add(name);
      if (names.length == 6) break;
    }
    return MusicStrings.andMore(names);
  }
}

abstract final class MusicMixes {
  static const _minimum = 5;
  static const _size = 50;

  /// The mixes there's enough music for, in Home order.
  static Future<List<MusicMix>> build(MusicCatalog catalog) async {
    final random = Random();
    final results = await Future.wait([
      catalog.items(MediaKind.track, sort: 'addedAt', limit: 80),
      catalog.items(MediaKind.track, sort: 'random', limit: 80, filters: MusicCatalog.favoriteFilter),
      catalog.mostPlayed(limit: 80),
      catalog.items(MediaKind.track, sort: 'random', limit: 200),
    ].map((future) => future.catchError((Object _) => const <MediaItem>[])));
    final [recent, favorites, mostPlayed, random200] = results;

    List<MediaItem> mixOf(Iterable<MediaItem> tracks, {bool shuffle = true}) {
      final seen = <String>{};
      final list = [for (final track in tracks) if (seen.add(track.globalKey)) track];
      if (shuffle) list.shuffle(random);
      return list.take(_size).toList();
    }

    final mixes = <MusicMix>[
      MusicMix(
        id: 'new-music',
        title: (top: MusicStrings.mixNewMusic, bottom: MusicStrings.mix),
        hueShift: 0,
        tracks: mixOf(recent),
      ),
      MusicMix(
        id: 'favorites',
        title: (top: MusicStrings.mixFavorites, bottom: MusicStrings.mix),
        hueShift: 24,
        tracks: mixOf([...favorites, ...mostPlayed.take(30)]),
      ),
      MusicMix(
        id: 'discovery',
        title: (top: MusicStrings.mixDiscovery, bottom: MusicStrings.mix),
        hueShift: -30,
        tracks: mixOf(random200.where((track) => (track.viewCount ?? 0) == 0)),
      ),
      MusicMix(
        id: 'replay',
        title: (top: MusicStrings.mixReplay, bottom: MusicStrings.mix),
        hueShift: 50,
        tracks: mixOf(mostPlayed, shuffle: false),
      ),
    ];
    return [for (final mix in mixes) if (mix.tracks.length >= _minimum) mix];
  }
}
