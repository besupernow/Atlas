/// Atlas: music mode's labels in one place, ready to move into the translation files. English
/// only for now.
abstract final class MusicStrings {
  static const home = 'Home';
  static const newTab = 'New';
  static const radio = 'Radio';
  static const library = 'Library';
  static const search = 'Search';
  static const nowPlaying = 'Now Playing';

  static const recentlyPlayed = 'Recently Played';
  static const recentlyAdded = 'Recently Added';
  static const mostPlayed = 'Your Most Played';
  static const favorites = 'Your Favorites';
  static const mixes = 'Stations for You';
  static const artistsToExplore = 'Artists to Explore';
  static const newReleases = 'New Releases';
  static const newSinglesAndEps = 'New Singles & EPs';
  static const latestAlbums = 'Latest Albums';

  static const yourStation = 'Your Station';
  static const yourStationSubtitle = 'Songs you love, and more like them';
  static const artistStations = 'Artist Stations';
  static const genreStations = 'Genre Stations';

  static const playlists = 'Playlists';
  static const artists = 'Artists';
  static const albums = 'Albums';
  static const songs = 'Songs';
  static const genres = 'Genres';

  static const topSongs = 'Top Songs';
  static const albumsSection = 'Albums';
  static const singlesAndEps = 'Singles & EPs';
  static const live = 'Live';
  static const compilations = 'Compilations';
  static const similarArtists = 'Similar Artists';
  static const about = 'About';
  static const station = 'Station';

  static const searchHint = 'Artists, albums and songs';
  static const nothingYet = 'No music here yet.';
  static const noResults = 'No results.';
  static const loadFailed = "Couldn't load this. Pull to try again.";
  static const loadMore = 'Load more';

  // Discovery.
  static const topPicks = 'Top Picks for You';
  static const featured = 'Featured';
  static const recommendedForYou = 'Recommended for You';
  static const recommendedSubtitle = 'From what you play, on the server or not (yet)';
  static const pickedForYou = 'Picked for You';
  static const pickedSubtitle = 'Already on the server';
  static String moreLike(String artist) => 'More Like $artist';
  static const moreLikeSubtitle = 'Artists you might love';
  static const popularThisWeek = 'Popular This Week';
  static const popularSubtitle = "What everyone's playing";
  static const trendingArtists = 'Trending Artists';
  static const newForYou = 'New From Artists You Play';
  static const newForYouSubtitle = 'Out in the last month';
  static const newEverywhere = 'New This Month';
  static const newEverywhereSubtitle = 'Albums and EPs, fresh out';
  static const hotRightNow = 'Hot Right Now';
  static const stationsSubtitle = 'Endless mixes from your server';

  static const notOnServer = 'Not on the server';
  static const request = 'Request';
  static const requesting = 'Requesting…';
  static const requested = 'Requested';
  static const downloading = 'Downloading';
  static const onServer = 'On the Server';
  static const open = 'Open';
  static const play = 'Play';
  static const shuffle = 'Shuffle';
  static const preview = 'Preview';
  static const stop = 'Stop';
  static const tracks = 'Tracks';
  static const noPreview = 'No preview for this one';
  static const requestFailed = "Couldn't request it. Try again in a bit.";
  static String requestNoMatch(String title) =>
      "$title isn't on MusicBrainz yet, and Lidarr only gets what MusicBrainz lists. Try again once it's been added.";
  static const feat = 'feat.';
  static const share = 'Share';
  static const copyName = 'Copy Name';
  static const copied = 'Copied';
  static const hideSong = 'Hide Song';
  static const hideAlbum = 'Hide Album';
  static String hideArtist(String name) => 'Hide $name';
  static String hidden(String title) => "Hidden. You won't see or hear $title again.";
  static const undo = 'Undo';
  static const hiddenMusic = 'Hidden Music';
  static const hiddenMusicSubtitle = "Artists, albums and songs you never want to see or hear";
  static const hiddenMusicEmpty = 'Nothing hidden. Long-press an artist, album or song and choose Hide to keep it out of music mode.';
  static const unhide = 'Unhide';
  static const hiddenArtist = 'Artist';
  static String hiddenAlbumBy(String artist) => artist.isEmpty ? 'Album' : 'Album · $artist';
  static String hiddenSongBy(String artist) => artist.isEmpty ? 'Song' : 'Song · $artist';
  static String noArtistProfile(String name) => "$name doesn't have an artist profile to show.";
  static String released(String date) => 'Released $date';
  static const musicBrainzBusy = "MusicBrainz is busy right now, so Lidarr's id for it couldn't be looked up. Try again in a minute.";
  static const requestSent = "Requested. It'll show up in your music when it's ready.";
  static const requestUnavailable = "Requests need Allseerr, and it isn't connected right now.";
  static const discography = 'Discography';
  static const albumsAndEps = 'Albums & EPs';
  static const singles = 'Singles';
  static const openOnServer = 'Open on the Server';

  // ListenBrainz (each user's account is set by an admin on the server).
  static const listenBrainz = 'ListenBrainz';
  static const usernameHint = 'ListenBrainz username';
  static const save = 'Save';
  static const cancel = 'Cancel';
  static const remove = 'Remove';
  static const userNotFound = "That ListenBrainz user doesn't exist.";
  static const listenBrainzAccounts = 'ListenBrainz Accounts';
  static const listenBrainzAccountsSubtitle = "Pick whose ListenBrainz account goes with each person's Atlas account";
  static const listenBrainzAccountsHint = 'Each person gets recommendations from their own account';
  static const listenBrainzNotSet = 'Not set';
  static const listenBrainzNoServer = 'Music settings need the Atlas server, and it isn\'t connected right now.';
  static const listenBrainzServerOld =
      "Couldn't load the accounts. The server may need the Atlas update that stores ListenBrainz names.";
  static const listenBrainzSaveFailed = "Couldn't save it on the server. Try again in a bit.";

  // Library.
  static const libraryEmpty = 'Favorite albums, artists and songs, and the playlists you make, live here.';
  static const favoriteAlbums = 'Favorite Albums';
  static const recentlyFavorited = 'In Your Library';

  // Now Playing.
  static const nothingPlaying = 'Nothing playing';
  static const nothingPlayingBody = 'Pick an album, a song or a station and it shows up here.';
  static const browseMusic = 'Browse Music';
  static const upNext = 'Up Next';

  // Home (Apple Music style).
  static const madeForYou = 'Made for You';
  static const listenAgain = 'Listen Again';
  static const recommended = 'Recommended';
  static String featuring(String artist) => 'Featuring $artist';
  static String stationLike(String artist) => 'Endless music like $artist';
  static const newReleasesForYou = 'New Releases for You';
  static const stationsForYou = 'Stations for You';
  static const atlasMusic = 'Atlas';
  static const mix = 'Mix';
  static const mixNewMusic = 'New Music';
  static const mixFavorites = 'Favorites';
  static const mixDiscovery = 'Discovery';
  static const mixReplay = 'Replay';
  static String andMore(List<String> names) => names.isEmpty
      ? ''
      : names.length < 3
      ? names.join(', ')
      : '${names.join(', ')} and more';

  // Settings (music mode).
  static const settingsMusic = 'Music';
  static const musicPlayback = 'Music Playback';
  static const musicPlaybackSubtitle = 'Streaming quality and picking up where you left off';

  // New and discovery (round 3).
  static String likeArtist(String artist) => 'Like $artist';
  static const kickerForYou = 'FOR YOU';
  static const kickerOutNow = 'OUT NOW';
  static const kickerTrending = 'TRENDING';
  static const kickerCharts = 'CHARTS';
  static const kickerPopular = 'POPULAR';
  static const kickerJustPlayed = 'JUST PLAYED';
  static const kickerFromYourServer = 'ON THE SERVER';
  static const kickerMixes = 'MIXES';
  static const kickerFresh = 'FRESH';
  static const topSongsSubtitle = 'The most played songs right now';
  static const topAlbums = 'Top Albums';
  static const topAlbumsSubtitle = 'The most played albums right now';
  static const topArtists = 'Artists Everyone Is Playing';
  static const newReleasesSubtitle = 'Picked by editors this week';
  static const newRelease = 'New Release';
  static const openAlbum = 'Open album';
  static const label = 'Label';

  // Context menu and Now Playing (round 4).
  static const viewDetails = 'View Details';
  static const goToArtist = 'Go to Artist';
  static const goToAlbum = 'Go to Album';
  static const playNext = 'Play Next';
  static const addToQueue = 'Add to Queue';
  static const startStation = 'Start Station';
  static const love = 'Love';
  static const unlove = 'Remove Love';
  static const loved = 'Loved';
  static const unloved = 'Removed from Loved';
  static const addToPlaylist = 'Add to Playlist';
  static const newPlaylist = 'New Playlist';
  static const playlistName = 'Playlist name';
  static const addedToPlaylist = 'Added to playlist';
  static const willPlayNext = 'Plays next';
  static const addedToQueue = 'Added to the queue';
  static const lyricsTab = 'Lyrics';
  static const playingTab = 'Playing';

  // Release page.
  static const singleLabel = 'Single';
  static const epLabel = 'EP';
  static const albumLabel = 'Album';
  static const compilationLabel = 'Compilation';
  static String songCount(int count) => count == 1 ? '1 song' : '$count songs';
  static String minutes(int count) => count == 1 ? '1 minute' : '$count minutes';
  static String moreBy(String artist) => artist.isEmpty ? 'More Like This' : 'More by $artist';

  // Search.
  static const searchHintEverywhere = 'Artists, albums, songs';
  static const searchEmptyHint = 'Search your server and everything else. Anything we don\'t have can be previewed and requested.';
  static const topResult = 'Top Result';
  static const artistLabel = 'Artist';
  static const more = 'More';
  static const everywhere = 'Everywhere';
  static const songLabel = 'Song';

  // Dynamic categories.
  static String becauseYouListened(String artist) => 'Because You Listened to $artist';
  static String genrePicks(String genre) => '$genre Picks for You';
  static const genrePicksSubtitle = "What's big in a sound you play a lot";
  static const rediscover = 'Rediscover';
  static const rediscoverSubtitle = "From your server, not played in a while";
  static String newInGenre(String genre) => 'New in $genre';
  static String topInGenre(String genre) => 'Top $genre Albums';
  static const newInGenreSubtitle = 'This week, picked by editors';
}
