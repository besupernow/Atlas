import 'package:flutter/material.dart';

import '../discover/allseerr_music.dart';
import '../discover/deezer.dart';
import '../discover/discover_feed.dart';
import '../discover/music_feed_page.dart';
import '../music_strings.dart';
import '../widgets/top_songs.dart';

/// Atlas: music mode's New, the way Apple Music's works: what just came out and what everybody
/// is playing right now, out in the world (not what's new on the server). New releases and the
/// charts come from Deezer (much better artwork and metadata than MusicBrainz), new music from
/// the artists you play comes from ListenBrainz. Anything we don't have can be previewed and
/// requested from its card.
class MusicNewPage extends StatelessWidget {
  const MusicNewPage({super.key});

  static final _specs = [
    MusicFeedSpec(
      id: 'new-releases',
      load: (d) async => MusicFeedRow(
        id: 'new-releases',
        kicker: MusicStrings.kickerOutNow,
        title: MusicStrings.newReleases,
        subtitle: MusicStrings.newReleasesSubtitle,
        large: true,
        // The first six are in the banner.
        items: (await d.newReleases()).skip(6).toList(),
        seeAll: () => d.newReleases(limit: 100),
      ),
    ),
    MusicFeedSpec(
      id: 'top-songs',
      load: (d) async {
        final tracks = await quietly(Deezer.topTracks(limit: 40), const <ChartTrack>[], 'top songs');
        if (tracks.isEmpty) return null;
        return MusicFeedRow(
          id: 'top-songs',
          title: MusicStrings.topSongs,
          custom: (context, focusRail) => TopSongsShelf(tracks: tracks, onNavigateToSidebar: focusRail),
        );
      },
    ),
    MusicFeedSpec(
      id: 'new-for-you',
      load: (d) async => MusicFeedRow(
        id: 'new-for-you',
        kicker: MusicStrings.kickerForYou,
        title: MusicStrings.newForYou,
        subtitle: MusicStrings.newForYouSubtitle,
        items: await d.newForYou(),
      ),
    ),
    MusicFeedSpec(
      id: 'top-albums',
      load: (d) async => MusicFeedRow(
        id: 'top-albums',
        kicker: MusicStrings.kickerCharts,
        title: MusicStrings.topAlbums,
        subtitle: MusicStrings.topAlbumsSubtitle,
        ranked: true,
        items: await d.topAlbums(limit: 25),
        seeAll: () => d.topAlbums(limit: 100),
      ),
    ),
    MusicFeedSpec(
      id: 'top-artists',
      load: (d) async => MusicFeedRow(
        id: 'top-artists',
        kicker: MusicStrings.kickerPopular,
        title: MusicStrings.topArtists,
        items: await d.topArtists(),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) => MusicFeedPage(
    title: MusicStrings.newTab,
    heroEyebrow: MusicStrings.newRelease,
    specs: _specs,
    // The banner: the six newest releases.
    heroLoader: (d) async => (await d.newReleases()).take(6).toList(),
  );
}
