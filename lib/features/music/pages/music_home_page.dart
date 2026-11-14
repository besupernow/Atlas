import 'dart:async';

import 'package:flutter/material.dart';

import '../../../media/media_item.dart';
import '../../../utils/music_navigation.dart';
import '../discover/allseerr_music.dart';
import '../discover/discover_feed.dart';
import '../discover/discover_models.dart';
import '../discover/listenbrainz_connect.dart';
import '../discover/music_feed_page.dart';
import '../discover/music_mixes.dart';
import '../music_strings.dart';
import '../widgets/top_picks.dart';

/// Atlas: music mode's Home, laid out like Apple Music's:
///
/// - Top Picks for You: tall cards mixing your mixes ("Made for You"), albums to play again
///   ("Listen Again"), an artist station ("Featuring …") and ListenBrainz picks
///   ("Recommended", on the server or not yet).
/// - Recently Played (with "see all"), Made for You (the mixes), Recommended for You and New
///   Releases for You (mixed, with previews and requests), Stations for You, More Like your top
///   artist, Picked for You (already on the server), Recently Added.
class MusicHomePage extends StatefulWidget {
  const MusicHomePage({super.key});

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

/// What several rows share, fetched once per page load.
class _HomeData {
  _HomeData(MusicDiscovery d) {
    mixes = quietly(MusicMixes.build(d.catalog), const <MusicMix>[], 'mixes');
    recentlyPlayed = quietly(d.catalog.recentlyPlayed(), const <MediaItem>[], 'recently played');
    stations = quietly(d.catalog.stationArtists(limit: 12), const <MediaItem>[], 'stations');
    rawRecommendations = quietly(d.recommendations(), const <DiscoverAlbum>[], 'recommendations');
    recommendations = quietly(
      rawRecommendations.then((albums) async => d.resolve(albums, known: await d.known(), limit: 24)),
      const <MusicFeedItem>[],
      'recommendation cards',
    );
  }

  late final Future<List<MusicMix>> mixes;
  late final Future<List<MediaItem>> recentlyPlayed;
  late final Future<List<MediaItem>> stations;
  late final Future<List<DiscoverAlbum>> rawRecommendations;
  late final Future<List<MusicFeedItem>> recommendations;
}

class _MusicHomePageState extends State<MusicHomePage> {
  _HomeData? _data;
  MusicDiscovery? _forDiscovery;

  /// A new [MusicDiscovery] means a new page load (or a refresh).
  _HomeData _shared(MusicDiscovery d) {
    if (!identical(_forDiscovery, d) || _data == null) {
      _forDiscovery = d;
      _data = _HomeData(d);
    }
    return _data!;
  }

  static List<TopPick> _topPicks({
    required List<MusicMix> mixes,
    required List<MediaItem> recent,
    required List<MusicFeedItem> recommended,
    required List<MediaItem> stations,
  }) {
    final columns = <List<TopPick>>[
      [for (final mix in mixes) MixPick(mix)],
      [for (final track in recent.take(3)) ItemPick(ServerFeedItem(track), MusicStrings.listenAgain)],
      [for (final item in recommended.take(3)) ItemPick(item, MusicStrings.recommended)],
      [for (final artist in stations.take(1)) StationPick(artist)],
    ];
    final picks = <TopPick>[];
    for (var round = 0; picks.length < 9; round++) {
      var added = false;
      for (final column in columns) {
        if (round < column.length) {
          picks.add(column[round]);
          added = true;
        }
      }
      if (!added) break;
    }
    return picks.take(9).toList();
  }

  late final List<MusicFeedSpec> _specs = [
    MusicFeedSpec(
      id: 'top-picks',
      load: (d) async {
        final data = _shared(d);
        final picks = _topPicks(
          mixes: await data.mixes,
          recent: await data.recentlyPlayed,
          recommended: await data.recommendations,
          stations: await data.stations,
        );
        if (picks.isEmpty) return null;
        return MusicFeedRow(
          id: 'top-picks',
          title: MusicStrings.topPicks,
          custom: (context, focusRail) => TopPicksShelf(picks: picks, onNavigateToSidebar: focusRail),
        );
      },
    ),
    MusicFeedSpec(
      id: 'recently-played',
      load: (d) async => MusicFeedRow(
        id: 'recently-played',
        title: MusicStrings.recentlyPlayed,
        items: MusicDiscovery.server(await _shared(d).recentlyPlayed),
        seeAll: () async => MusicDiscovery.server(await d.catalog.recentlyPlayed(limit: 60)),
      ),
    ),
    MusicFeedSpec(
      id: 'connect',
      load: (d) async {
        if (d.listenBrainz != null) return null;
        return MusicFeedRow(
          id: 'connect',
          title: MusicStrings.connectTitle,
          custom: (context, focusRail) => ListenBrainzConnectCard(onNavigateLeft: focusRail),
        );
      },
    ),
    MusicFeedSpec(
      id: 'made-for-you',
      load: (d) async {
        final mixes = await _shared(d).mixes;
        if (mixes.isEmpty) return null;
        return MusicFeedRow(
          id: 'made-for-you',
          title: MusicStrings.madeForYou,
          custom: (context, focusRail) => MixShelf(mixes: mixes, onNavigateToSidebar: focusRail),
        );
      },
    ),
    MusicFeedSpec(
      id: 'recommended',
      load: (d) async => MusicFeedRow(
        id: 'recommended',
        title: MusicStrings.recommendedForYou,
        subtitle: MusicStrings.recommendedSubtitle,
        // The first few are already in Top Picks.
        items: (await _shared(d).recommendations).skip(3).toList(),
      ),
    ),
    MusicFeedSpec(
      id: 'new-for-you',
      load: (d) async => MusicFeedRow(
        id: 'new-for-you',
        title: MusicStrings.newReleasesForYou,
        subtitle: MusicStrings.newForYouSubtitle,
        items: await d.newForYou(),
      ),
    ),
    MusicFeedSpec(
      id: 'stations',
      onItemTap: (item) {
        if (item is ServerFeedItem) unawaited(playInstantMix(context, item.item));
      },
      load: (d) async => MusicFeedRow(
        id: 'stations',
        title: MusicStrings.stationsForYou,
        subtitle: MusicStrings.stationsSubtitle,
        items: MusicDiscovery.server(await _shared(d).stations),
      ),
    ),
    MusicFeedSpec(
      id: 'more-like',
      load: (d) async {
        final row = await d.moreLike();
        if (row == null) return null;
        return MusicFeedRow(
          id: 'more-like',
          title: MusicStrings.moreLike(row.artist),
          subtitle: MusicStrings.moreLikeSubtitle,
          items: row.items,
        );
      },
    ),
    MusicFeedSpec(
      id: 'picked',
      load: (d) async => MusicFeedRow(
        id: 'picked',
        title: MusicStrings.pickedForYou,
        subtitle: MusicStrings.pickedSubtitle,
        items: await d.pickedForYou(await _shared(d).rawRecommendations),
      ),
    ),
    MusicFeedSpec(
      id: 'recently-added',
      load: (d) async => MusicFeedRow(
        id: 'recently-added',
        title: MusicStrings.recentlyAdded,
        items: MusicDiscovery.server(await d.catalog.recentlyAddedAlbums()),
        seeAll: () async => MusicDiscovery.server(await d.catalog.recentlyAddedAlbums(limit: 100)),
      ),
    ),
  ];

  static List<MusicFeedItem> _noHero(Map<String, MusicFeedRow> rows) => const [];

  @override
  Widget build(BuildContext context) {
    return MusicFeedPage(
      title: MusicStrings.home,
      heroEyebrow: MusicStrings.topPicks,
      specs: _specs,
      hero: _noHero,
    );
  }
}
