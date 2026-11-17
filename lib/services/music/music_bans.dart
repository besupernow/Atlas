import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/app_logger.dart';
import '../settings_service.dart';

enum MusicBanKind { artist, album, song }

/// One thing a person never wants to see or hear: an artist, an album or a song. Matched by
/// server id when it came from the server, and always by name (artist, and title for albums
/// and songs), so the same thing from Deezer, Last.fm or TIDAL is caught too.
@immutable
class MusicBan {
  const MusicBan({required this.kind, required this.title, this.artist = '', this.id});

  final MusicBanKind kind;

  /// The artist's name, or the album's or song's title.
  final String title;

  /// Who it's by (albums and songs).
  final String artist;

  /// The server's id, when it came from the server.
  final String? id;

  String get key => switch (kind) {
    MusicBanKind.artist => MusicBans.artistKey(title),
    MusicBanKind.album => MusicBans.releaseKey(artist, title),
    MusicBanKind.song => MusicBans.releaseKey(artist, title),
  };

  Map<String, Object?> toJson() => {'kind': kind.name, 'title': title, 'artist': artist, 'id': ?id};

  static MusicBan? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = MusicBanKind.values.where((value) => value.name == json['kind']).firstOrNull;
    final title = json['title'];
    if (kind == null || title is! String || title.isEmpty) return null;
    return MusicBan(kind: kind, title: title, artist: json['artist'] as String? ?? '', id: json['id'] as String?);
  }

  @override
  bool operator ==(Object other) => other is MusicBan && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);
}

/// Atlas: each person's hidden artists, albums and songs. Kept per profile on this device.
/// Everything music shows or plays asks here first: server lists ([filter]), outside results
/// ([blocksNames]), and the player, which skips anything hidden in a queue, station or mix.
class MusicBans extends ChangeNotifier {
  MusicBans._();

  static final MusicBans instance = MusicBans._();

  String? _profile;
  List<MusicBan> _bans = const [];
  Set<String> _ids = const {};
  Set<String> _artists = const {};
  Set<String> _albums = const {};
  Set<String> _songs = const {};

  List<MusicBan> get bans => List.unmodifiable(_bans);
  bool get isEmpty => _bans.isEmpty;

  static StringPref _pref(String profile) => StringPref('atlas_music_bans_$profile');

  /// Load the bans of [profile] (null: nobody signed in, nothing hidden).
  void useProfile(String? profile) {
    if (profile == _profile) return;
    _profile = profile;
    var bans = <MusicBan>[];
    if (profile != null) {
      try {
        final raw = SettingsService.instance.read(_pref(profile));
        if (raw.isNotEmpty) {
          final list = jsonDecode(raw);
          if (list is List) bans = [for (final entry in list) ?MusicBan.fromJson(entry)];
        }
      } catch (error) {
        appLogger.w('Music: reading hidden music failed', error: error);
      }
    }
    _set(bans);
  }

  Future<void> add(MusicBan ban) async {
    if (_bans.contains(ban)) return;
    _set([..._bans, ban]);
    await _save();
  }

  Future<void> remove(MusicBan ban) async {
    _set([for (final existing in _bans) if (existing != ban) existing]);
    await _save();
  }

  bool contains(MusicBan ban) => _bans.contains(ban);

  void _set(List<MusicBan> bans) {
    _bans = bans;
    _ids = {for (final ban in bans) ?ban.id};
    _artists = {for (final ban in bans) if (ban.kind == MusicBanKind.artist) ban.key};
    _albums = {for (final ban in bans) if (ban.kind == MusicBanKind.album) ban.key};
    _songs = {for (final ban in bans) if (ban.kind == MusicBanKind.song) ban.key};
    notifyListeners();
  }

  Future<void> _save() async {
    final profile = _profile;
    if (profile == null) return;
    await SettingsService.instance.write(_pref(profile), jsonEncode([for (final ban in _bans) ban.toJson()]));
  }

  // ---- Matching.

  static String _normal(String value) =>
      value.toLowerCase().replaceAll('&', 'and').replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static final _extras = RegExp(
    r'\s*[(\[](?:feat\.?|ft\.?|featuring|with|[^)\]]*\b(?:remaster(?:ed)?|deluxe|edition|explicit)\b)[^)\]]*[)\]]|\s+-\s+(?:single|ep)$',
    caseSensitive: false,
  );

  static String artistKey(String name) => _normal(name);

  static String releaseKey(String artist, String title) =>
      '${_normal(_primary(artist))}|${_normal(title.replaceAll(_extras, ''))}';

  static String _primary(String artist) =>
      artist.split(RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\s+|,\s+(?!the\b)|\s+&\s+', caseSensitive: false)).first;

  /// Everyone credited, for artist matching ("A, B feat. C" → A, B, C).
  static Iterable<String> _artistsOf(String? credit) => (credit ?? '')
      .split(RegExp(r'\s+(?:feat\.?|ft\.?|featuring|with|x)\s+|,\s+(?!the\b)|\s+&\s+', caseSensitive: false))
      .map(_normal)
      .where((name) => name.isNotEmpty);

  /// Whether anything about [item] (from the server) is hidden: itself, its album, or anyone
  /// credited on it.
  bool blocks(MediaItem item) {
    if (_bans.isEmpty) return false;
    if (_ids.contains(item.id)) return true;
    switch (item.kind) {
      case MediaKind.artist:
        return _artists.contains(artistKey(item.title ?? ''));
      case MediaKind.album:
        if (item.grandparentId != null && _ids.contains(item.grandparentId)) return true;
        final artist = item.albumArtistTitle ?? '';
        return _albums.contains(releaseKey(artist, item.title ?? '')) || _artistsOf(artist).any(_artists.contains);
      case MediaKind.track:
        if ((item.parentId != null && _ids.contains(item.parentId)) ||
            (item.grandparentId != null && _ids.contains(item.grandparentId))) {
          return true;
        }
        final albumArtist = item.albumArtistTitle ?? item.trackArtistTitle ?? '';
        final artist = item.trackArtistTitle ?? albumArtist;
        return _songs.contains(releaseKey(artist, item.title ?? '')) ||
            _songs.contains(releaseKey(albumArtist, item.title ?? '')) ||
            _albums.contains(releaseKey(albumArtist, item.albumTitle ?? '')) ||
            _artistsOf(artist).any(_artists.contains) ||
            _artistsOf(albumArtist).any(_artists.contains);
      default:
        return false;
    }
  }

  /// Whether something from outside the server is hidden, by its names: an artist alone, an
  /// album ([album] with [artist]), or a song ([song] with [artist], and its [album]).
  bool blocksNames({required String artist, String? album, String? song, List<String> featuring = const []}) {
    if (_bans.isEmpty) return false;
    if (_artistsOf(artist).any(_artists.contains) || featuring.map(_normal).any(_artists.contains)) return true;
    if (album != null && _albums.contains(releaseKey(artist, album))) return true;
    if (song != null && _songs.contains(releaseKey(artist, song))) return true;
    return false;
  }

  /// [items] without anything hidden.
  List<MediaItem> filter(List<MediaItem> items) =>
      _bans.isEmpty ? items : [for (final item in items) if (!blocks(item)) item];
}
