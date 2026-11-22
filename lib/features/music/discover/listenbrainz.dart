import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../../profiles/active_profile_provider.dart';
import '../../../services/base_shared_preferences_service.dart';
import '../../../services/settings_service.dart';
import '../../../utils/app_logger.dart';
import '../data/music_server.dart';
import 'discover_models.dart';

/// Atlas: each person's ListenBrainz username comes from their Jellyfin account on the Atlas
/// server (an admin sets it there, see [ListenBrainzAccounts]), so nobody signs in to anything
/// in the app. The last name the server gave is kept per profile so pages have it right away;
/// [refresh] asks the server again.
abstract final class ListenBrainzAccount {
  static StringPref _pref(String profileId) => StringPref('atlas_listenbrainz_from_server_$profileId');

  static String? _profileId(BuildContext context) {
    try {
      return context.read<ActiveProfileProvider>().activeId;
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// The username for the current profile, or null.
  static String? username(BuildContext context) {
    final profile = _profileId(context);
    if (profile == null) return null;
    final name = SettingsService.instance.read(_pref(profile)).trim();
    return name.isEmpty ? null : name;
  }

  static final Map<String, DateTime> _checkedAt = {};
  static final Map<String, Future<void>> _inFlight = {};

  /// Ask the server for this profile's username (at most every few minutes unless [force]).
  /// Pages listening to [changes] reload when it changes.
  static Future<void> refresh(BuildContext context, {bool force = false}) {
    final profile = _profileId(context);
    final client = MusicServer.jellyfin(context);
    if (profile == null || client == null) return Future.value();
    final last = _checkedAt[profile];
    if (!force && last != null && DateTime.now().difference(last) < const Duration(minutes: 5)) {
      return Future.value();
    }
    return _inFlight.putIfAbsent(profile, () async {
      try {
        final name = await client.atlasListenBrainzUserName();
        _checkedAt[profile] = DateTime.now();
        final pref = _pref(profile);
        if (SettingsService.instance.read(pref).trim() != (name ?? '')) {
          await SettingsService.instance.write(pref, name ?? '');
          changes.value++;
        }
      } catch (error) {
        // Offline: keep the name we had.
        appLogger.w('ListenBrainz: reading the username from the server failed', error: error);
      } finally {
        unawaited(_inFlight.remove(profile));
      }
    });
  }

  /// Bumped when the username changes, so pages reload.
  static final changes = ValueNotifier<int>(0);

  /// Whether [username] exists on ListenBrainz.
  static Future<bool> exists(String username) async {
    final response = await ListenBrainz._get('/user/${Uri.encodeComponent(username.trim())}/listen-count');
    return response != null;
  }
}

/// A recommendation from ListenBrainz before we know whether it's on the server.
class ListenBrainzAlbum {
  const ListenBrainzAlbum({
    required this.releaseGroupMbid,
    required this.title,
    required this.artistName,
    this.artistMbid,
    this.coverUrl,
    this.year,
    this.score = 0,
    this.hits = 1,
    this.type,
  });

  final String releaseGroupMbid;
  final String title;
  final String artistName;
  final String? artistMbid;
  final String? coverUrl;
  final String? year;
  final double score;

  /// How many of the recommended songs are on this album (more = surer bet).
  final int hits;

  /// MusicBrainz primary type when known ("Album", "EP", "Single").
  final String? type;

  DiscoverAlbum toDiscover({DiscoverStatus status = DiscoverStatus.notRequested, String? reason}) => DiscoverAlbum(
    mbid: releaseGroupMbid,
    title: title,
    artistName: artistName,
    artistMbid: artistMbid,
    coverUrl: coverUrl ?? DiscoverAlbum.coverArtArchiveUrl(releaseGroupMbid),
    releaseDate: year,
    status: status,
    reason: reason,
  );
}

/// Atlas: the public ListenBrainz API for one person: what it recommends for them, their
/// weekly playlists, new releases from artists they play, and their top artists.
class ListenBrainz {
  ListenBrainz(this.username);

  final String username;

  static const _base = 'https://api.listenbrainz.org/1';
  static const _headers = {'User-Agent': 'Atlas/1.0 (family music app)', 'Accept': 'application/json'};

  String get _user => Uri.encodeComponent(username);

  static Future<Object?> _get(String path, {Map<String, String>? query}) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: query);
    final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
    if (response.statusCode == 204 || response.statusCode == 404) return null;
    if (response.statusCode != 200) throw http.ClientException('ListenBrainz ${response.statusCode}', uri);
    return jsonDecode(response.body);
  }

  /// Albums ListenBrainz's collaborative filtering thinks this person will like, best first.
  Future<List<ListenBrainzAlbum>> recommendedAlbums({int recordings = 100}) async {
    final data = await _get('/cf/recommendation/user/$_user/recording', query: {'count': '$recordings'});
    final payload = data is Map ? data['payload'] : null;
    final mbids = payload is Map ? payload['mbids'] : null;
    if (mbids is! List) return const [];
    final scores = <String, double>{
      for (final entry in mbids)
        if (entry is Map && entry['recording_mbid'] is String)
          entry['recording_mbid'] as String: (entry['score'] as num?)?.toDouble() ?? 0,
    };
    return _albumsForRecordings(scores);
  }

  /// The albums behind this week's "Weekly Exploration" playlist (new to them, picked for them).
  Future<List<ListenBrainzAlbum>> weeklyExplorationAlbums() => _createdForAlbums('weekly-exploration');

  /// The albums behind "Weekly Jams" (what they've loved lately).
  Future<List<ListenBrainzAlbum>> weeklyJamsAlbums() => _createdForAlbums('weekly-jams');

  /// New releases (last 30 days) from artists this person listens to.
  Future<List<ListenBrainzAlbum>> freshReleases({int days = 30}) async {
    final data = await _get(
      '/user/$_user/fresh_releases',
      query: {'days': '$days', 'sort': 'release_date', 'past': 'true', 'future': 'false'},
    );
    final payload = data is Map ? data['payload'] : null;
    final releases = payload is Map ? payload['releases'] : null;
    if (releases is! List) return const [];
    final seen = <String>{};
    final albums = <ListenBrainzAlbum>[];
    for (final release in releases.reversed) {
      if (release is! Map) continue;
      final id = release['release_group_mbid'];
      if (id is! String || !seen.add(id)) continue;
      final mbids = release['artist_mbids'];
      final secondary = release['release_group_secondary_type'];
      albums.add(
        ListenBrainzAlbum(
          type: secondary is String && secondary.isNotEmpty
              ? secondary
              : release['release_group_primary_type'] as String?,
          releaseGroupMbid: id,
          title: release['release_name'] as String? ?? '',
          artistName: release['artist_credit_name'] as String? ?? '',
          artistMbid: mbids is List && mbids.isNotEmpty ? mbids.first as String? : null,
          coverUrl: _cover(release['caa_release_mbid'], release['caa_id']),
          year: release['release_date'] as String?,
        ),
      );
    }
    return albums;
  }

  /// When this person last listened to anything (null: never, or not public).
  Future<DateTime?> lastListenedAt() async {
    final data = await _get('/user/$_user/listens', query: {'count': '1'});
    final payload = data is Map ? data['payload'] : null;
    final listens = payload is Map ? payload['listens'] : null;
    final first = listens is List && listens.isNotEmpty ? listens.first : null;
    final at = first is Map ? first['listened_at'] : null;
    return at is num ? DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000) : null;
  }

  /// This person's most played artists this month: (mbid, name).
  Future<List<({String mbid, String name})>> topArtists({int count = 5, String range = 'month'}) async {
    final data = await _get('/stats/user/$_user/artists', query: {'count': '$count', 'range': range});
    final payload = data is Map ? data['payload'] : null;
    final artists = payload is Map ? payload['artists'] : null;
    if (artists is! List) return const [];
    return [
      for (final artist in artists)
        if (artist is Map && artist['artist_mbid'] is String && artist['artist_name'] is String)
          (mbid: artist['artist_mbid'] as String, name: artist['artist_name'] as String),
    ];
  }

  /// The albums (release groups) this person actually played in [range] ("week", "month",
  /// "quarter", "half_yearly", "year", "all_time"), most played first: (mbid, title, artist,
  /// listens). Auto-add uses it to see which of its picks got listened to.
  Future<List<({String mbid, String title, String artist, int listens})>> topReleaseGroups({
    int count = 100,
    String range = 'quarter',
  }) async {
    final data = await _get('/stats/user/$_user/release-groups', query: {'count': '$count', 'range': range});
    final payload = data is Map ? data['payload'] : null;
    final groups = payload is Map ? payload['release_groups'] : null;
    if (groups is! List) return const [];
    return [
      for (final group in groups)
        if (group is Map && group['release_group_mbid'] is String)
          (
          mbid: group['release_group_mbid'] as String,
          title: group['release_group_name'] as String? ?? '',
          artist: group['artist_name'] as String? ?? '',
          listens: (group['listen_count'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  /// An artist's most-listened albums across everyone on ListenBrainz, most popular first
  /// (the "start here" albums). Not tied to a person.
  static Future<List<ListenBrainzAlbum>> popularAlbums(String artistMbid, {required String artistName}) async {
    final data = await _get('/popularity/top-release-groups-for-artist/${Uri.encodeComponent(artistMbid)}');
    if (data is! List) return const [];
    final albums = <ListenBrainzAlbum>[];
    for (final entry in data) {
      if (entry is! Map || entry['release_group_mbid'] is! String) continue;
      final group = entry['release_group'];
      final name = group is Map ? group['name'] as String? : null;
      if (name == null || name.isEmpty) continue;
      albums.add(
        ListenBrainzAlbum(
          releaseGroupMbid: entry['release_group_mbid'] as String,
          title: name,
          artistName: artistName,
          artistMbid: artistMbid,
          coverUrl: group is Map ? _cover(group['caa_release_mbid'], group['caa_id']) : null,
          year: group is Map ? (group['date'] as String?)?.split('-').first : null,
          type: group is Map ? group['type'] as String? : null,
          score: (entry['total_listen_count'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
    return albums;
  }

  Future<List<ListenBrainzAlbum>> _createdForAlbums(String sourcePatch) async {
    final data = await _get('/user/$_user/playlists/createdfor', query: {'count': '25'});
    final playlists = data is Map ? data['playlists'] : null;
    if (playlists is! List) return const [];
    String? id;
    for (final entry in playlists) {
      final playlist = entry is Map ? entry['playlist'] : null;
      if (playlist is! Map) continue;
      final extension = playlist['extension'];
      final jspf = extension is Map ? extension['https://musicbrainz.org/doc/jspf#playlist'] : null;
      final meta = jspf is Map ? jspf['additional_metadata'] : null;
      final algorithm = meta is Map ? meta['algorithm_metadata'] : null;
      final patch = algorithm is Map ? algorithm['source_patch'] : null;
      final title = (playlist['title'] as String? ?? '').toLowerCase();
      if (patch == sourcePatch || title.contains(sourcePatch.replaceAll('-', ' '))) {
        id = (playlist['identifier'] as String?)?.split('/').where((part) => part.isNotEmpty).last;
        break; // Newest first.
      }
    }
    if (id == null) return const [];
    final playlistData = await _get('/playlist/$id');
    final playlist = playlistData is Map ? playlistData['playlist'] : null;
    final tracks = playlist is Map ? playlist['track'] : null;
    if (tracks is! List) return const [];
    final recordings = <String, double>{};
    var rank = tracks.length.toDouble();
    for (final track in tracks) {
      final identifiers = track is Map ? track['identifier'] : null;
      final identifier = identifiers is List ? identifiers.firstOrNull : identifiers;
      if (identifier is String) recordings[identifier.split('/').last] = rank--;
    }
    return _albumsForRecordings(recordings);
  }

  /// Recordings to their albums (release groups), keeping the best score per album.
  Future<List<ListenBrainzAlbum>> _albumsForRecordings(Map<String, double> recordings) async {
    final byAlbum = <String, ListenBrainzAlbum>{};
    final hits = <String, int>{};
    final ids = recordings.keys.toList();
    for (var start = 0; start < ids.length; start += 25) {
      final chunk = ids.sublist(start, start + 25 > ids.length ? ids.length : start + 25);
      final data = await _get(
        '/metadata/recording/',
        query: {'recording_mbids': chunk.join(','), 'inc': 'artist release'},
      );
      if (data is! Map) continue;
      for (final MapEntry(:key, :value) in data.entries) {
        if (value is! Map) continue;
        final release = value['release'];
        if (release is! Map) continue;
        final group = release['release_group_mbid'];
        if (group is! String) continue;
        final score = recordings[key] ?? 0;
        final existing = byAlbum[group];
        hits[group] = (hits[group] ?? 0) + 1;
        if (existing != null && existing.score >= score) continue;
        final artist = value['artist'];
        final artists = artist is Map ? artist['artists'] : null;
        final firstArtist = artists is List && artists.isNotEmpty ? artists.first : null;
        byAlbum[group] = ListenBrainzAlbum(
          releaseGroupMbid: group,
          title: release['name'] as String? ?? '',
          artistName: release['album_artist_name'] as String? ??
              (artist is Map ? artist['name'] as String? : null) ??
              '',
          artistMbid: firstArtist is Map ? firstArtist['artist_mbid'] as String? : null,
          coverUrl: _cover(release['caa_release_mbid'], release['caa_id']),
          year: release['year']?.toString(),
          score: score,
        );
      }
    }
    final albums = [
      for (final album in byAlbum.values)
        if (album.title.isNotEmpty)
          ListenBrainzAlbum(
            releaseGroupMbid: album.releaseGroupMbid,
            title: album.title,
            artistName: album.artistName,
            artistMbid: album.artistMbid,
            coverUrl: album.coverUrl,
            year: album.year,
            score: album.score,
            hits: hits[album.releaseGroupMbid] ?? 1,
          ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return albums;
  }

  static String? _cover(Object? releaseMbid, Object? caaId) => releaseMbid is String && caaId != null
      ? 'https://archive.org/download/mbid-$releaseMbid/mbid-$releaseMbid-${caaId}_thumb500.jpg'
      : null;

  @visibleForTesting
  static String? coverFor(Object? releaseMbid, Object? caaId) => _cover(releaseMbid, caaId);
}
