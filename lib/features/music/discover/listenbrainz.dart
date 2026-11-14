import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../../profiles/active_profile_provider.dart';
import '../../../services/base_shared_preferences_service.dart';
import '../../../services/settings_service.dart';
import 'discover_models.dart';

/// Atlas: each person's ListenBrainz account, by username, per profile. Reading
/// recommendations and stats needs only the name (they're public); scrobbling (later) will add
/// the token through the sidecar.
abstract final class ListenBrainzAccount {
  static StringPref _pref(String profileId) => StringPref('atlas_listenbrainz_user_$profileId');

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

  static Future<void> setUsername(BuildContext context, String? username) async {
    final profile = _profileId(context);
    if (profile == null) return;
    await SettingsService.instance.write(_pref(profile), username?.trim() ?? '');
    changes.value++;
  }

  /// Bumped when someone connects or disconnects, so pages reload.
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
  });

  final String releaseGroupMbid;
  final String title;
  final String artistName;
  final String? artistMbid;
  final String? coverUrl;
  final String? year;
  final double score;

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
      albums.add(
        ListenBrainzAlbum(
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
    final albums = byAlbum.values.where((album) => album.title.isNotEmpty).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return albums;
  }

  static String? _cover(Object? releaseMbid, Object? caaId) => releaseMbid is String && caaId != null
      ? 'https://archive.org/download/mbid-$releaseMbid/mbid-$releaseMbid-${caaId}_thumb500.jpg'
      : null;

  @visibleForTesting
  static String? coverFor(Object? releaseMbid, Object? caaId) => _cover(releaseMbid, caaId);
}
