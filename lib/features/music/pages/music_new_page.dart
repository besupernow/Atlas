import 'package:flutter/material.dart';

import '../discover/discover_feed.dart';
import '../discover/discover_models.dart';
import '../discover/music_feed_page.dart';
import '../music_strings.dart';

/// Atlas: music mode's New: what's actually new out there, not what's new on the server.
/// Fresh albums and EPs from the last few weeks (ListenBrainz, through Allseerr), new music
/// from the artists you play, what everyone's spinning this week, and who's trending. Anything
/// we don't have can be previewed and requested right from the card.
class MusicNewPage extends StatelessWidget {
  const MusicNewPage({super.key});

  static final _specs = [
    MusicFeedSpec(
      id: 'new-for-you',
      load: (d) async => MusicFeedRow(
        id: 'new-for-you',
        title: MusicStrings.newForYou,
        subtitle: MusicStrings.newForYouSubtitle,
        large: true,
        items: await d.newForYou(),
      ),
    ),
    MusicFeedSpec(
      id: 'new-everywhere',
      load: (d) async => MusicFeedRow(
        id: 'new-everywhere',
        title: MusicStrings.newEverywhere,
        subtitle: MusicStrings.newEverywhereSubtitle,
        items: await d.newReleases(),
      ),
    ),
    MusicFeedSpec(
      id: 'hot',
      load: (d) async => MusicFeedRow(
        id: 'hot',
        title: MusicStrings.hotRightNow,
        subtitle: MusicStrings.popularSubtitle,
        items: await d.popularAlbums(),
      ),
    ),
    MusicFeedSpec(
      id: 'trending-artists',
      load: (d) async => MusicFeedRow(
        id: 'trending-artists',
        title: MusicStrings.trendingArtists,
        items: await d.trendingArtists(),
      ),
    ),
  ];

  static List<MusicFeedItem> _hero(Map<String, MusicFeedRow> rows) {
    final everywhere = rows['new-everywhere']?.items ?? const [];
    final forYou = rows['new-for-you']?.items ?? const [];
    return [...forYou.take(3), ...everywhere].take(6).toList();
  }

  @override
  Widget build(BuildContext context) => MusicFeedPage(
    title: MusicStrings.newTab,
    heroEyebrow: MusicStrings.newReleases,
    specs: _specs,
    hero: _hero,
    emptyMessage: MusicStrings.requestUnavailable,
  );
}
