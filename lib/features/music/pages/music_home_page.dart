import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../utils/music_navigation.dart';
import '../../../widgets/app_icon.dart';
import '../discover/discover_feed.dart';
import '../discover/discover_models.dart';
import '../discover/listenbrainz.dart';
import '../discover/listenbrainz_connect.dart';
import '../discover/music_feed_page.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';

/// Atlas: music mode's Home.
///
/// Server-only rows: Recently Played, Picked for You (what's here that fits you), Stations,
/// Recently Added, Your Favorites. Mixed rows (on the server or not, with previews and
/// requests): Recommended for You (ListenBrainz), More Like your top artist, Popular This Week.
class MusicHomePage extends StatefulWidget {
  const MusicHomePage({super.key});

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

class _MusicHomePageState extends State<MusicHomePage> {
  /// ListenBrainz's picks, shared by the rows that use them (one fetch per load).
  Future<List<DiscoverAlbum>>? _recommendations;
  int _loadId = -1;

  Future<List<DiscoverAlbum>> _recs(MusicDiscovery discovery) {
    // A new MusicDiscovery means a new page load.
    final id = identityHashCode(discovery);
    if (_loadId != id || _recommendations == null) {
      _loadId = id;
      _recommendations = discovery.recommendations();
    }
    return _recommendations!;
  }

  late final List<MusicFeedSpec> _specs = [
    MusicFeedSpec(
      id: 'recently-played',
      load: (d) async => MusicFeedRow(
        id: 'recently-played',
        title: MusicStrings.recentlyPlayed,
        items: MusicDiscovery.server(await d.catalog.recentlyPlayed()),
      ),
    ),
    MusicFeedSpec(
      id: 'recommended',
      load: (d) async => MusicFeedRow(
        id: 'recommended',
        title: MusicStrings.recommendedForYou,
        subtitle: MusicStrings.recommendedSubtitle,
        large: true,
        items: await d.resolve(await _recs(d), known: await d.known(), limit: 24),
      ),
    ),
    MusicFeedSpec(
      id: 'picked',
      load: (d) async => MusicFeedRow(
        id: 'picked',
        title: MusicStrings.pickedForYou,
        subtitle: MusicStrings.pickedSubtitle,
        items: await d.pickedForYou(await _recs(d)),
      ),
    ),
    MusicFeedSpec(
      id: 'stations',
      onItemTap: (item) {
        if (item is ServerFeedItem) unawaited(playInstantMix(context, item.item));
      },
      load: (d) async => MusicFeedRow(
        id: 'stations',
        title: MusicStrings.mixes,
        subtitle: MusicStrings.stationsSubtitle,
        items: MusicDiscovery.server(await d.catalog.stationArtists(limit: 12)),
      ),
    ),
    MusicFeedSpec(
      id: 'recently-added',
      load: (d) async => MusicFeedRow(
        id: 'recently-added',
        title: MusicStrings.recentlyAdded,
        items: MusicDiscovery.server(await d.catalog.recentlyAddedAlbums()),
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
      id: 'popular',
      load: (d) async => MusicFeedRow(
        id: 'popular',
        title: MusicStrings.popularThisWeek,
        subtitle: MusicStrings.popularSubtitle,
        items: await d.popularAlbums(),
      ),
    ),
    MusicFeedSpec(
      id: 'favorites',
      load: (d) async => MusicFeedRow(
        id: 'favorites',
        title: MusicStrings.favorites,
        items: MusicDiscovery.server(await d.catalog.favoriteAlbums()),
      ),
    ),
  ];

  /// The banner: the best recommendations, else what just landed on the server.
  List<MusicFeedItem> _hero(Map<String, MusicFeedRow> rows) {
    final recommended = rows['recommended']?.items ?? const [];
    if (recommended.length >= 3) return recommended.take(6).toList();
    return [...recommended, ...?rows['recently-added']?.items].take(6).toList();
  }

  @override
  Widget build(BuildContext context) {
    final focus = MusicShellFocus.maybeOf(context);
    return ValueListenableBuilder<int>(
      valueListenable: ListenBrainzAccount.changes,
      builder: (context, _, _) {
        final connected = ListenBrainzAccount.username(context) != null;
        return MusicFeedPage(
        title: MusicStrings.home,
        heroEyebrow: MusicStrings.topPicks,
        specs: _specs,
        hero: _hero,
        actions: [
          IconButton(
            tooltip: MusicStrings.listenBrainz,
            icon: AppIcon(connected ? Symbols.account_circle_rounded : Symbols.person_add_rounded, fill: 1.0),
            onPressed: () => unawaited(showListenBrainzConnect(context)),
          ),
        ],
        header: connected ? null : (_) => ListenBrainzConnectCard(onNavigateLeft: focus?.focusRail),
        );
      },
    );
  }
}
