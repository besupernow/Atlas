import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../providers/seerr_account_provider.dart';
import '../../../services/seerr/seerr_client.dart';
import '../../../services/seerr/seerr_exceptions.dart';
import '../../../utils/app_logger.dart';
import '../music_strings.dart';
import 'discover_models.dart';
import 'music_resolver.dart';
import 'musicbrainz.dart';

/// Atlas: music discovery and requests through Allseerr (our Seerr, which already talks to
/// ListenBrainz, MusicBrainz, the Cover Art Archive and Lidarr). The same session the app uses
/// for movie and show requests; nothing extra to sign in to.
class AllseerrMusic {
  AllseerrMusic(this._client);

  final SeerrClient _client;

  /// Null when Allseerr isn't connected for this profile.
  static AllseerrMusic? of(BuildContext context) {
    final SeerrAccountProvider? account;
    try {
      account = context.read<SeerrAccountProvider?>();
    } on ProviderNotFoundException {
      return null;
    }
    final client = account?.catalogClient;
    return client == null ? null : AllseerrMusic(client);
  }

  /// Albums and EPs released in the last few weeks, everywhere (ListenBrainz fresh releases).
  Future<List<DiscoverAlbum>> freshReleases({int page = 1}) => _albums('/discover/music', page);

  /// The albums the most people are playing on ListenBrainz this week.
  Future<List<DiscoverAlbum>> topAlbums({int page = 1}) => _albums('/discover/music/albums', page);

  /// The artists the most people are playing this week.
  Future<List<DiscoverArtist>> topArtists({int page = 1}) async {
    final data = await _client.getJson('/discover/music/artists', query: {'page': page});
    return _artists(data);
  }

  /// Artists like the one with [artistMbid].
  Future<List<DiscoverArtist>> similarArtists(String artistMbid, {String? reason}) async {
    final data = await _client.getJson('/artist/$artistMbid/similar');
    return _artists(data, reason: reason);
  }

  /// An artist's albums, EPs and singles, newest first.
  Future<List<DiscoverAlbum>> discography(String artistMbid) async {
    final data = await _client.getJson('/artist/$artistMbid/discography');
    final groups = data is Map<String, dynamic> ? data['releaseGroups'] : null;
    final albums = [
      if (groups is List)
        for (final json in groups) ?DiscoverAlbum.fromSeerr(json),
    ];
    return _withOverrides(albums.reversed.toList());
  }

  /// The album with its track list, for the request sheet.
  Future<DiscoverAlbumDetails> album(DiscoverAlbum album) async {
    final data = await _client.getJson('/music/${album.mbid}') as Map<String, dynamic>;
    final media = data['mediaInfo'];
    final artist = data['artist'];
    final tracks = data['tracks'];
    final genres = data['genres'];
    final wiki = data['artistWikipedia'];
    final status = DiscoverStatus.fromSeerr(media is Map ? media['status'] : null);
    return DiscoverAlbumDetails(
      album: DiscoverAlbum(
        mbid: album.mbid,
        title: data['title'] as String? ?? album.title,
        artistName: data['artistCredit'] as String? ??
            (artist is Map ? artist['name'] as String? : null) ??
            album.artistName,
        artistMbid: (artist is Map ? artist['id'] as String? : null) ?? album.artistMbid,
        coverUrl: data['posterPath'] as String? ?? album.coverUrl,
        releaseDate: data['releaseDate'] as String? ?? album.releaseDate,
        type: data['type'] as String? ?? album.type,
        status: StatusOverrides.instance.statusOf(album.mbid) ?? status,
      ),
      tracks: [
        if (tracks is List)
          for (final track in tracks)
            if (track is Map<String, dynamic>)
              DiscoverTrack(
                title: track['name'] as String? ?? '',
                number: '${track['number'] ?? track['position'] ?? ''}',
                disc: (track['disc'] as num?)?.toInt() ?? 1,
                length: track['length'] is num ? Duration(milliseconds: (track['length'] as num).toInt()) : null,
                artist: _creditOf(track['artists']),
              ),
      ],
      genres: [
        if (genres is List)
          for (final genre in genres)
            if (genre is String) genre else if (genre is Map && genre['name'] is String) genre['name'] as String,
      ],
      artistImageUrl: data['artistThumb'] as String?,
      artistBackdropUrl: data['artistBackdrop'] as String?,
      about: wiki is Map ? wiki['content'] as String? ?? wiki['extract'] as String? : (wiki is String ? wiki : null),
    );
  }

  /// Ask for [album]. Allseerr sends it to Lidarr (auto-approved for the family).
  /// Albums from Deezer or Last.fm get their MusicBrainz release group from their codes first
  /// ([MusicResolver]). Throws a [MusicRequestException] with something worth showing when it
  /// can't go through.
  Future<DiscoverStatus> request(DiscoverAlbum album) async {
    final DiscoverAlbum? target;
    try {
      target = await MusicResolver.releaseGroup(album);
    } on MusicBrainzBusy catch (error) {
      throw MusicRequestException(MusicStrings.musicBrainzBusy, cause: error);
    }
    if (target == null) throw MusicRequestException(MusicStrings.requestNoMatch(album.title));
    DiscoverStatus status;
    // Atlas: Allseerr checks the album with MusicBrainz itself. Give MusicBrainz a moment
    // after our own lookups (we share the house's allowance), and when it still answers
    // Allseerr with 503 (busy), wait it out and try again instead of failing the request.
    await MusicBrainz.settle();
    for (var attempt = 1; ; attempt++) {
      try {
        final data = await _client.postJson('/request', {'mediaType': 'music', 'mediaId': target.mbid});
        final media = data is Map<String, dynamic> ? data['media'] : null;
        status = DiscoverStatus.fromSeerr(media is Map ? media['status'] : null);
        if (!status.onServer && !status.inProgress) status = DiscoverStatus.requested;
        break;
      } on SeerrApiException catch (error) {
        // Someone in the house already asked for it: that's a yes, not a failure.
        if (error.statusCode == 409) {
          status = DiscoverStatus.requested;
          break;
        }
        if (_musicBrainzBusy(error) && attempt < 4) {
          appLogger.d('Music request: MusicBrainz busy for Allseerr, retrying (${target.title})');
          await Future<void>.delayed(Duration(seconds: 2 * attempt * attempt));
          continue;
        }
        appLogger.w('Music request: Allseerr refused ${target.title} (${target.mbid})', error: error);
        if (_musicBrainzBusy(error)) throw MusicRequestException(MusicStrings.musicBrainzBusy, cause: error);
        throw MusicRequestException(error.message.trim().isEmpty ? MusicStrings.requestFailed : error.message, cause: error);
      } on SeerrPermissionException catch (error) {
        throw MusicRequestException(error.display, cause: error);
      }
    }
    StatusOverrides.instance.set(target.mbid, status);
    StatusOverrides.instance.set(album.mbid, status);
    return status;
  }

  /// Allseerr passing on MusicBrainz's "busy" (503 / rate limited), which goes away on retry.
  static bool _musicBrainzBusy(SeerrApiException error) {
    final message = error.message.toLowerCase();
    return error.statusCode == 503 ||
        error.statusCode == 429 ||
        (message.contains('musicbrainz') && (message.contains('503') || message.contains('rate') || message.contains('unavailable')));
  }

  /// Every album Allseerr knows the household has or asked for, by release group id. Used to
  /// mark albums from ListenBrainz as on the server or on their way.
  Future<Map<String, DiscoverStatus>> knownAlbums() async {
    final known = <String, DiscoverStatus>{};
    const take = 500;
    for (var skip = 0; skip < 5000; skip += take) {
      final data = await _client.getJson('/media', query: {'mediaType': 'music', 'take': take, 'skip': skip});
      final results = data is Map<String, dynamic> ? data['results'] : null;
      if (results is! List || results.isEmpty) break;
      for (final media in results) {
        if (media is Map<String, dynamic> && media['mbId'] is String) {
          known[media['mbId'] as String] = DiscoverStatus.fromSeerr(media['status']);
        }
      }
      if (results.length < take) break;
    }
    return known;
  }

  Future<List<DiscoverAlbum>> _albums(String path, int page) async {
    final data = await _client.getJson(path, query: {'page': page});
    final results = data is Map<String, dynamic> ? data['results'] : null;
    final albums = [
      if (results is List)
        for (final json in results) ?DiscoverAlbum.fromSeerr(json),
    ];
    return _withOverrides(albums);
  }

  List<DiscoverArtist> _artists(Object? data, {String? reason}) {
    final results = data is Map<String, dynamic> ? data['results'] : null;
    return [
      if (results is List)
        for (final json in results) ?DiscoverArtist.fromSeerr(json, reason: reason),
    ];
  }

  static List<DiscoverAlbum> _withOverrides(List<DiscoverAlbum> albums) => [
    for (final album in albums)
      if (StatusOverrides.instance.statusOf(album.mbid) case final status?) album.copyWith(status: status) else album,
  ];

  static String? _creditOf(Object? artists) {
    if (artists is! List || artists.isEmpty) return null;
    return artists.map((artist) => artist is Map ? artist['name'] : null).whereType<String>().join(', ');
  }
}

/// Requests made in this session, so every row showing the album updates at once.
class StatusOverrides extends ChangeNotifier {
  StatusOverrides._();

  static final instance = StatusOverrides._();

  final Map<String, DiscoverStatus> _statuses = {};

  DiscoverStatus? statusOf(String mbid) => _statuses[mbid];

  void set(String mbid, DiscoverStatus status) {
    if (_statuses[mbid] == status) return;
    _statuses[mbid] = status;
    notifyListeners();
  }
}

/// Logs and swallows a failed discovery read: a row that can't load is just left out.
Future<T> quietly<T>(Future<T> future, T fallback, String what) async {
  try {
    return await future;
  } catch (error) {
    appLogger.w('Music discovery: $what failed', error: error);
    return fallback;
  }
}

/// A music request that didn't go through, with a [message] fit for a snackbar.
class MusicRequestException implements Exception {
  const MusicRequestException(this.message, {this.cause});

  final String message;
  final Object? cause;

  /// What to tell the person for any failure from [AllseerrMusic.request].
  static String describe(Object error) => error is MusicRequestException ? error.message : MusicStrings.requestFailed;

  @override
  String toString() => 'MusicRequestException: $message${cause == null ? '' : ' ($cause)'}';
}
