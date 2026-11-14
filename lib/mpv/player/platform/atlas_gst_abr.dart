import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../../utils/app_logger.dart';

/// Atlas adaptive streaming on Linux (GStreamer): which rendition plays, and when to change it.
///
/// The Linux twin of `AtlasWarmGate.kt` (Android) and `AtlasAVWarmGate.swift` (Apple). GStreamer's
/// hlsdemux2 can be pinned to one rendition (`min-bitrate`..`max-bitrate`), switches at the next
/// segment without throwing away what it has buffered, and can be told to stop buffering further
/// ahead (`max-buffering-time`). So this decides everything itself:
///
/// - Playback opens pinned to the lowest rung, the one the server started transcoding when it handed
///   out the playlist.
/// - About once a second it reads the measured bandwidth and works out the best rung the connection
///   carries. To go up, it asks the server to warm that rung from where the buffer ends (POST
///   `/Videos/{id}/AtlasWarm`), stops buffering further ahead meanwhile, and moves the pin only once
///   the server says those segments are on disk. Because hlsdemux2 switches exactly at the end of the
///   buffer, every segment it then asks for is one the warm-up already made.
/// - Going down never waits: a connection that can't carry the current rung (and a buffer running
///   low), or a stall soon after a step up, moves the pin straight down. A rung that stalled is left
///   alone for 1, 2, 4 ... up to 10 minutes.
class AtlasGstAbr {
  AtlasGstAbr({required this.invoke, required this.stats});

  /// The player's method channel (`setAbrLimits`).
  final Future<void> Function(String method, Map<String, Object?> args) invoke;

  /// The player's native stats (`getStats`).
  final Future<Map<String, dynamic>> Function() stats;

  static const _bandwidthFraction = 0.85;
  static const _minBufferForUpswitchMs = 6000;

  /// While a warm-up is pending, buffer only this far ahead. hlsdemux2 switches where its buffer
  /// ends, so this is about how long after "ready" the new rendition shows (rather than the 15 s it
  /// buffers otherwise), and it gives the warm-up a fixed point to catch up to.
  static const _holdBufferMs = 6000;
  static const _giveUpAfter = Duration(seconds: 30);
  static const _stallWindow = Duration(seconds: 30);

  Timer? _timer;
  int _generation = 0;
  _Endpoint? _endpoint;
  List<_Level> _levels = const [];
  Map<String, String> _headers = const {};
  final http.Client _http = http.Client();

  int _pin = 0;
  int? _target;
  DateTime _targetSince = DateTime.now();
  bool _requestInFlight = false;
  bool _holding = false;
  int _tooSlowTicks = 0;

  DateTime? _lastUpswitchAt;
  int _lastUpswitchFrom = 0;
  DateTime _lastSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _started = false;
  bool _wasBuffering = false;
  final Map<String, DateTime> _backoffUntil = {};
  final Map<String, Duration> _backoffFor = {};

  bool get active => _endpoint != null && _levels.isNotEmpty;

  /// The rendition playback is pinned to (or about to switch to, once the buffer reaches it).
  String? get pinnedLevel => active ? _levels[_pin].id : null;

  /// Its BANDWIDTH, in bits per second.
  int? get pinnedBandwidth => active ? _levels[_pin].bandwidth : null;

  /// A new playback. Anything that isn't an Atlas adaptive master leaves GStreamer to choose.
  void start(String url, Map<String, String>? headers) {
    stop();
    final generation = ++_generation;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.queryParameters['AtlasAbr']?.toLowerCase() != 'true') return;
    final playSessionId = uri.queryParameters['PlaySessionId'];
    final marker = uri.path.toLowerCase().indexOf('/videos/');
    if (playSessionId == null || marker < 0) return;
    final itemId = uri.path.substring(marker + 8).split('/').first;
    if (itemId.isEmpty) return;
    _endpoint = _Endpoint(
      base: '${uri.scheme}://${uri.authority}${uri.path.substring(0, marker)}',
      itemId: itemId,
      apiKey: uri.queryParameters['ApiKey'] ?? uri.queryParameters['api_key'],
      playSessionId: playSessionId,
    );
    _headers = Map.of(headers ?? const {});
    unawaited(_fetchLadder(uri, generation));
  }

  /// Playback ended or was replaced.
  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _endpoint = null;
    _levels = const [];
    _pin = 0;
    _target = null;
    _requestInFlight = false;
    _holding = false;
    _tooSlowTicks = 0;
    _lastUpswitchAt = null;
    _started = false;
    _wasBuffering = false;
    _backoffUntil.clear();
    _backoffFor.clear();
  }

  void dispose() {
    stop();
    _http.close();
  }

  /// A seek: whatever was warming started from the old position.
  void onSeek() {
    _lastSeekAt = DateTime.now();
    if (_target != null) _log('seek, dropping the warm-up');
    _target = null;
    unawaited(_releaseHold());
  }

  Future<void> _fetchLadder(Uri master, int generation) async {
    try {
      final response = await _http.get(master, headers: _headers).timeout(const Duration(seconds: 15));
      if (generation != _generation || response.statusCode != 200) return;
      final levels = _parseLevels(response.body, master)..sort((a, b) => a.bandwidth.compareTo(b.bandwidth));
      if (levels.isEmpty) return;
      _levels = levels;
      _log('ladder: ${levels.map((l) => '${l.id} ${l.bandwidth ~/ 1000}k').join(', ')}');
      await _pinTo(0);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick(generation)));
    } catch (e) {
      _log('could not read the ladder ($e); GStreamer picks renditions itself');
    }
  }

  static List<_Level> _parseLevels(String text, Uri base) {
    final levels = <_Level>[];
    int? pendingBandwidth;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingBandwidth = null;
        for (final part in line.substring(line.indexOf(':') + 1).split(',')) {
          final eq = part.indexOf('=');
          if (eq > 0 && part.substring(0, eq) == 'BANDWIDTH') pendingBandwidth = int.tryParse(part.substring(eq + 1));
        }
      } else if (line.isNotEmpty && !line.startsWith('#') && pendingBandwidth != null) {
        final level = base.resolve(line).queryParameters['AtlasLevel'];
        if (level != null) levels.add(_Level(level, pendingBandwidth));
        pendingBandwidth = null;
      }
    }
    return levels;
  }

  Future<void> _tick(int generation) async {
    if (generation != _generation || !active) return;
    final s = await stats();
    if (generation != _generation) return;
    final now = DateTime.now();
    final buffered = (s['totalBufferedDurationMs'] as num?)?.toInt() ?? 0;
    final positionMs = (s['positionMs'] as num?)?.toInt() ?? 0;
    final estimate = (s['bandwidthEstimate'] as num?)?.toDouble() ?? 0;
    final buffering = s['buffering'] == true;
    if (s['playing'] == true) _started = true;

    // A stall mid-play (not the start, not a seek) right after a step up: that step was too far.
    if (buffering && !_wasBuffering && _started && now.difference(_lastSeekAt) > const Duration(seconds: 3)) {
      _onStall(now);
    }
    _wasBuffering = buffering;
    if (estimate <= 0) return;

    // Down: the connection can't carry this rung and the buffer is going.
    if (_pin > 0 && _levels[_pin].bandwidth > estimate * _bandwidthFraction && buffered < 8000) {
      if (++_tooSlowTicks >= 3) {
        var down = _pin - 1;
        while (down > 0 && _levels[down].bandwidth > estimate * _bandwidthFraction) {
          down--;
        }
        _log('connection dropped to ${estimate ~/ 1000} kbps; down to ${_levels[down].id}');
        _target = null;
        await _releaseHold();
        await _pinTo(down);
        _tooSlowTicks = 0;
        return;
      }
    } else {
      _tooSlowTicks = 0;
    }

    // Up: the best rung this connection carries.
    int? want;
    for (var index = _levels.length - 1; index > _pin; index--) {
      final until = _backoffUntil[_levels[index].id];
      if (until != null && now.isBefore(until)) continue;
      if (_levels[index].bandwidth <= estimate * _bandwidthFraction) {
        want = index;
        break;
      }
    }
    if (want == null || (buffered < _minBufferForUpswitchMs && _target == null)) {
      if (_target != null && want == null) {
        _log("connection can't carry ${_levels[_target!].id} any more; dropping the warm-up");
        _target = null;
      }
      await _releaseHold();
      return;
    }

    if (_target != want) {
      _target = want;
      _targetSince = now;
      _log(
        'want ${_levels[want].id} (${_levels[want].bandwidth ~/ 1000} kbps, estimate ${estimate ~/ 1000} kbps), '
        'warming from ${((positionMs + buffered) / 1000).toStringAsFixed(1)}s',
      );
    }
    if (now.difference(_targetSince) > _giveUpAfter) {
      final level = _levels[want];
      _log("${level.id} didn't warm up in ${_giveUpAfter.inSeconds}s; staying put for a while");
      _backoffUntil[level.id] = now.add(const Duration(minutes: 1));
      _target = null;
      await _releaseHold();
      return;
    }

    // Stop running ahead on the old rung while the new one catches up (see [_holdBufferMs]).
    if (!_holding) {
      _holding = true;
      await invoke('setAbrLimits', {'maxBufferingMs': _holdBufferMs});
    }

    // From where the buffer ends: hlsdemux2 switches there, and fetches onward from there.
    await _requestWarm(want, positionMs + buffered, generation);
  }

  void _onStall(DateTime now) {
    final at = _lastUpswitchAt;
    if (at == null || now.difference(at) > _stallWindow) return;
    final failed = _levels[_pin];
    final hold = _backoffFor[failed.id] ?? const Duration(minutes: 1);
    _backoffFor[failed.id] = Duration(seconds: math.min(hold.inSeconds * 2, 600));
    _backoffUntil[failed.id] = now.add(hold);
    _log('stalled after stepping up to ${failed.id}; back to ${_levels[_lastUpswitchFrom].id} for ${hold.inSeconds}s');
    _lastUpswitchAt = null;
    unawaited(_pinTo(_lastUpswitchFrom));
  }

  Future<void> _requestWarm(int index, int fromMs, int generation) async {
    final endpoint = _endpoint;
    if (_requestInFlight || endpoint == null) return;
    final level = _levels[index];
    final url = Uri.parse('${endpoint.base}/Videos/${endpoint.itemId}/AtlasWarm').replace(
      queryParameters: {
        'PlaySessionId': endpoint.playSessionId,
        'Level': level.id,
        'PositionTicks': '${math.max(0, fromMs) * 10000}',
        if (endpoint.apiKey != null) 'ApiKey': endpoint.apiKey!,
      },
    );
    _requestInFlight = true;
    try {
      final response = await _http.post(url, headers: _headers).timeout(const Duration(seconds: 10));
      if (generation != _generation) return;
      if (response.statusCode == 404) {
        // The server doesn't know this playback (restarted, or predates warm-ups): let GStreamer choose.
        _log("server can't warm up ${level.id} (404); switching without warm-ups for this playback");
        _endpoint = null;
        _timer?.cancel();
        await invoke('setAbrLimits', {'minBitrate': 0, 'maxBitrate': 0, 'maxBufferingMs': -1});
        return;
      }
      final ready = RegExp(r'"Ready"\s*:\s*true', caseSensitive: false).hasMatch(response.body);
      if (!ready || _target != index) return;
      _log('${level.id} warmed up after ${DateTime.now().difference(_targetSince).inMilliseconds} ms, switching');
      _lastUpswitchFrom = _pin;
      _lastUpswitchAt = DateTime.now();
      _target = null;
      await _pinTo(index);
      await _releaseHold();
    } catch (e) {
      if (generation == _generation) _log('warm request for ${level.id} failed: $e');
    } finally {
      if (generation == _generation) _requestInFlight = false;
    }
  }

  /// Exactly one rendition: hlsdemux2 picks among those whose BANDWIDTH sits between the bounds.
  Future<void> _pinTo(int index) async {
    if (index < 0 || index >= _levels.length) return;
    _pin = index;
    final bandwidth = _levels[index].bandwidth;
    await invoke('setAbrLimits', {'minBitrate': (bandwidth * 0.99).floor(), 'maxBitrate': (bandwidth * 1.01).ceil()});
  }

  Future<void> _releaseHold() async {
    if (!_holding) return;
    _holding = false;
    await invoke('setAbrLimits', {'maxBufferingMs': -1});
  }

  void _log(String message) => appLogger.i('[abr] $message');
}

class _Level {
  const _Level(this.id, this.bandwidth);
  final String id;
  final int bandwidth;
}

class _Endpoint {
  const _Endpoint({required this.base, required this.itemId, required this.apiKey, required this.playSessionId});
  final String base;
  final String itemId;
  final String? apiKey;
  final String playSessionId;
}
