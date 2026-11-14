import 'dart:math';

import 'package:flutter/painting.dart';

import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../data/music_catalog.dart';
import '../music_strings.dart';

/// Atlas: a mix made from the server for this person, like Apple Music's "Made for You" mixes.
/// Built fresh on every Home load from what they favorite, play and haven't heard yet.
/// (AudioMuse-AI will add mood mixes like Chill and Get Up later.)
class MusicMix {
  const MusicMix({required this.id, required this.title, required this.colors, required this.tracks});

  final String id;

  /// Two lines on the art: "New Music" / "Mix".
  final ({String top, String bottom}) title;
  final List<Color> colors;
  final List<MediaItem> tracks;

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

  /// Art for the card's lower band.
  Color get bandColor => Color.lerp(colors.last, const Color(0xFF000000), 0.25)!;
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
        colors: const [Color(0xFFFF2D55), Color(0xFFFF7A59)],
        tracks: mixOf(recent),
      ),
      MusicMix(
        id: 'favorites',
        title: (top: MusicStrings.mixFavorites, bottom: MusicStrings.mix),
        colors: const [Color(0xFFFF5FA2), Color(0xFFFFB347)],
        tracks: mixOf([...favorites, ...mostPlayed.take(30)]),
      ),
      MusicMix(
        id: 'discovery',
        title: (top: MusicStrings.mixDiscovery, bottom: MusicStrings.mix),
        colors: const [Color(0xFF5E5CE6), Color(0xFF32ADE6)],
        tracks: mixOf(random200.where((track) => (track.viewCount ?? 0) == 0)),
      ),
      MusicMix(
        id: 'replay',
        title: (top: MusicStrings.mixReplay, bottom: MusicStrings.mix),
        colors: const [Color(0xFF30B158), Color(0xFF3FC8E4)],
        tracks: mixOf(mostPlayed, shuffle: false),
      ),
    ];
    return [for (final mix in mixes) if (mix.tracks.length >= _minimum) mix];
  }
}
