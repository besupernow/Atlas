import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../../services/music/music_playback_service.dart';
import '../../../utils/app_logger.dart';

/// One 30-second clip of a song.
class PreviewClip {
  const PreviewClip({required this.title, required this.url, this.number});

  final String title;
  final String url;
  final int? number;
}

/// Atlas: 30-second previews of albums that aren't on the server, from Deezer's public catalog
/// (no account needed), falling back to the iTunes Store's. Looked up by artist and title, and
/// remembered for the session.
abstract final class MusicPreviews {
  static final Map<String, Future<List<PreviewClip>>> _cache = {};
  static const _headers = {'User-Agent': 'Atlas/1.0', 'Accept': 'application/json'};

  /// Whether this platform can play previews (the system player: iOS, Android, macOS, web).
  static bool get supported => kIsWeb || Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  /// The album's clips in track order; empty when neither store has it.
  static Future<List<PreviewClip>> forAlbum(String artist, String album) {
    final key = '${_normal(artist)}|${_normal(album)}';
    return _cache.putIfAbsent(key, () async {
      try {
        final deezer = await _deezer(artist, album);
        if (deezer.isNotEmpty) return deezer;
      } catch (error) {
        appLogger.d('Music preview: Deezer lookup failed', error: error);
      }
      try {
        return await _itunes(artist, album);
      } catch (error) {
        appLogger.d('Music preview: iTunes lookup failed', error: error);
        _cache.remove(key);
        return const <PreviewClip>[];
      }
    });
  }

  static Future<List<PreviewClip>> _deezer(String artist, String album) async {
    final query = 'artist:"${artist.replaceAll('"', '')}" album:"${album.replaceAll('"', '')}"';
    final search = await _json(Uri.https('api.deezer.com', '/search/album', {'q': query, 'limit': '10'}));
    final results = search is Map ? search['data'] : null;
    if (results is! List || results.isEmpty) return const [];
    final best = _bestMatch(
      results.whereType<Map>().toList(),
      album,
      artist,
      titleOf: (entry) => entry['title'] as String? ?? '',
      artistOf: (entry) => (entry['artist'] is Map ? entry['artist']['name'] : null) as String? ?? '',
    );
    if (best == null) return const [];
    final tracks = await _json(Uri.https('api.deezer.com', '/album/${best['id']}/tracks', {'limit': '100'}));
    final data = tracks is Map ? tracks['data'] : null;
    if (data is! List) return const [];
    return [
      for (final track in data)
        if (track is Map && track['preview'] is String && (track['preview'] as String).isNotEmpty)
          PreviewClip(
            title: track['title_short'] as String? ?? track['title'] as String? ?? '',
            url: track['preview'] as String,
            number: (track['track_position'] as num?)?.toInt(),
          ),
    ];
  }

  static Future<List<PreviewClip>> _itunes(String artist, String album) async {
    final search = await _json(
      Uri.https('itunes.apple.com', '/search', {'term': '$artist $album', 'entity': 'album', 'limit': '10'}),
    );
    final results = search is Map ? search['results'] : null;
    if (results is! List || results.isEmpty) return const [];
    final best = _bestMatch(
      results.whereType<Map>().toList(),
      album,
      artist,
      titleOf: (entry) => entry['collectionName'] as String? ?? '',
      artistOf: (entry) => entry['artistName'] as String? ?? '',
    );
    if (best == null) return const [];
    final lookup = await _json(
      Uri.https('itunes.apple.com', '/lookup', {'id': '${best['collectionId']}', 'entity': 'song'}),
    );
    final songs = lookup is Map ? lookup['results'] : null;
    if (songs is! List) return const [];
    return [
      for (final song in songs)
        if (song is Map && song['wrapperType'] == 'track' && song['previewUrl'] is String)
          PreviewClip(
            title: song['trackName'] as String? ?? '',
            url: song['previewUrl'] as String,
            number: (song['trackNumber'] as num?)?.toInt(),
          ),
    ];
  }

  static Future<Object?> _json(Uri uri) async {
    final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    return jsonDecode(response.body);
  }

  /// The entry whose artist matches and whose title is closest, or null if nothing is close.
  static Map? _bestMatch(
    List<Map> entries,
    String album,
    String artist, {
    required String Function(Map) titleOf,
    required String Function(Map) artistOf,
  }) {
    final wantTitle = _normal(album);
    final wantArtist = _normal(artist);
    Map? best;
    var bestScore = 0;
    for (final entry in entries) {
      final gotArtist = _normal(artistOf(entry));
      final gotTitle = _normal(titleOf(entry));
      if (!(gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist)) || gotArtist.isEmpty) continue;
      final score = gotTitle == wantTitle
          ? 3
          : gotTitle.startsWith(wantTitle) || wantTitle.startsWith(gotTitle)
          ? 2
          : gotTitle.contains(wantTitle) || wantTitle.contains(gotTitle)
          ? 1
          : 0;
      if (score > bestScore) {
        bestScore = score;
        best = entry;
      }
    }
    return best;
  }

  static String _normal(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\((deluxe|expanded|remaster|anniversary|bonus)[^)]*\)|\[[^\]]*\]'), '')
      .replaceAll('&', 'and')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

/// Atlas: plays previews. One at a time, app-wide; music that was playing pauses for the clip
/// and carries on when it ends or is stopped (like Apple Music). A preview belongs to the page
/// it was started on: it stops when that page is closed or another page opens over it (menus
/// and sheets over it don't count).
class MusicPreviewPlayer extends ChangeNotifier {
  MusicPreviewPlayer._();

  static final instance = MusicPreviewPlayer._();

  VideoPlayerController? _controller;
  MusicPlaybackService? _pausedMusic;
  String? _playingKey;
  List<PreviewClip> _queue = const [];
  int _index = 0;
  bool _loading = false;
  Timer? _ticker;
  double _progress = 0;

  /// What's playing: the album's key (its MusicBrainz id) and the clip's index.
  String? get playingKey => _playingKey;
  int get index => _index;
  bool get loading => _loading;

  /// 0..1 through the current clip.
  double get progress => _progress;

  bool isPlaying(String key, {int? index}) => _playingKey == key && (index == null || index == _index);

  bool get active => _playingKey != null;

  VoidCallback? _unwatch;

  /// Stop when the page [context] is on goes away or gets covered by another page.
  void _watchPage(BuildContext context) {
    _unwatch?.call();
    _unwatch = null;
    final route = ModalRoute.of(context);
    if (route == null) return;
    final animation = route.animation;
    final covering = route.secondaryAnimation;
    void onPage(AnimationStatus status) {
      if (status == AnimationStatus.reverse || status == AnimationStatus.dismissed) unawaited(stop());
    }

    // Only another page drives this (a page route doesn't transition to sheets or menus).
    void onCovered(AnimationStatus status) {
      if (status == AnimationStatus.forward || status == AnimationStatus.completed) unawaited(stop());
    }

    animation?.addStatusListener(onPage);
    covering?.addStatusListener(onCovered);
    _unwatch = () {
      animation?.removeStatusListener(onPage);
      covering?.removeStatusListener(onCovered);
    };
  }

  /// Play [clips] of the album [key] from [startAt]; tapping the playing one stops it.
  Future<void> toggle(BuildContext context, String key, List<PreviewClip> clips, {int startAt = 0}) async {
    if (isPlaying(key, index: startAt)) return stop();
    if (clips.isEmpty) return;
    final music = context.read<MusicPlaybackService?>();
    _watchPage(context);
    await _stopController();
    if (_pausedMusic == null && music != null && music.isPlaying) {
      _pausedMusic = music;
      await music.pause();
    }
    _playingKey = key;
    _queue = clips;
    _index = startAt.clamp(0, clips.length - 1);
    await _open();
  }

  /// Play a whole album's previews in order, starting from the first.
  Future<void> playAlbum(BuildContext context, String key, Future<List<PreviewClip>> clips) async {
    if (_playingKey == key) return stop();
    _watchPage(context);
    _loading = true;
    _playingKey = key;
    notifyListeners();
    final list = await clips;
    _loading = false;
    if (_playingKey != key) return;
    if (list.isEmpty) {
      _playingKey = null;
      notifyListeners();
      return;
    }
    _playingKey = null;
    if (!context.mounted) return;
    await toggle(context, key, list);
  }

  Future<void> _open() async {
    final clip = _queue[_index];
    _loading = true;
    _progress = 0;
    notifyListeners();
    final controller = VideoPlayerController.networkUrl(Uri.parse(clip.url));
    _controller = controller;
    try {
      await controller.initialize();
      if (_controller != controller) return controller.dispose();
      await controller.play();
    } catch (error) {
      appLogger.w('Music preview: could not play ${clip.title}', error: error);
      if (_controller == controller) await stop();
      return;
    }
    _loading = false;
    controller.addListener(_onTick);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _onTick());
    notifyListeners();
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    final total = value.duration.inMilliseconds;
    _progress = total <= 0 ? 0 : (value.position.inMilliseconds / total).clamp(0.0, 1.0);
    notifyListeners();
    final finished =
        value.isCompleted || (total > 0 && value.position >= value.duration - const Duration(milliseconds: 150));
    if (finished) unawaited(_next());
  }

  Future<void> _next() async {
    if (_index + 1 >= _queue.length) return stop();
    _index++;
    await _stopController();
    await _open();
  }

  Future<void> _stopController() async {
    _ticker?.cancel();
    _ticker = null;
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_onTick);
    try {
      await controller.pause();
    } catch (_) {}
    await controller.dispose();
  }

  /// Stop the preview and resume any music it paused.
  Future<void> stop() async {
    _unwatch?.call();
    _unwatch = null;
    await _stopController();
    _playingKey = null;
    _loading = false;
    _progress = 0;
    notifyListeners();
    final music = _pausedMusic;
    _pausedMusic = null;
    if (music != null) await music.play();
  }

  /// Stop without resuming music (real playback is starting).
  Future<void> cancel() async {
    _pausedMusic = null;
    await stop();
  }
}
