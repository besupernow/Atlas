import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/app_logger.dart';
import 'intro_cache_stub.dart' if (dart.library.io) 'intro_cache_io.dart';

/// Where the seasonal intro clips live: `manifest.json` plus the mp4s it
/// names. Served by the atlas-share service (NPM strips `/atlas-share`).
const String kStartupIntroBase = 'https://atlas.besupernow.com/atlas-share/intro/';

/// One seasonal clip from the manifest.
class StartupIntroClip {
  final String id;

  /// Something the player can open: a file:// URI for a cached copy on
  /// native, otherwise the https URL.
  final String source;

  /// The clip has a soundtrack worth playing (TVs only, see the overlay).
  final bool sound;

  const StartupIntroClip({required this.id, required this.source, required this.sound});
}

/// Picks the clip for today from a small server-side manifest:
///
/// ```json
/// {
///   "intros": [
///     {"id": "halloween-2026", "from": "10-15", "to": "10-31", "file": "halloween-2026.mp4"},
///     {"id": "winter-2026", "from": "12-01", "to": "01-06", "file": "winter-2026.mp4", "sound": true},
///     {"id": "atlas", "file": "atlas.mp4"}
///   ]
/// }
/// ```
///
/// `from`/`to` are MM-DD and inclusive; a range can wrap the new year. The
/// first dated entry that matches today wins. An entry with no dates is the
/// default: it plays whenever no seasonal one does. No match and no default
/// means no intro.
///
/// The manifest is cached so launches decide instantly and refresh it in the
/// background. On native the clips are cached on disk too (downloaded ahead
/// of their start date) and played from that local file; a clip that isn't
/// on disk yet streams once while it downloads.
///
/// Web doesn't use this: `web/index.html` plays the clip itself, before
/// Flutter has even loaded, using the same manifest and date rules.
class StartupIntro {
  StartupIntro._();

  static const _prefsKey = 'atlas_startup_intro_manifest';

  /// How far ahead a clip is downloaded before its season starts.
  static const _prefetchDays = 14;

  static Future<StartupIntroClip?> pick() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, dynamic>? manifest = _decode(prefs.getString(_prefsKey));

      final refresh = _fetchManifest(prefs);
      if (manifest == null) {
        // First launch (or cleared data): wait a moment for the network, but
        // never hold startup for it.
        manifest = await refresh.timeout(const Duration(seconds: 4), onTimeout: () => null);
      } else {
        unawaited(refresh);
      }
      if (manifest == null) return null;

      final today = DateTime.now();
      final entry = _activeEntry(manifest, today);
      if (entry == null) return null;

      final id = entry['id'] as String;
      final url = _urlFor(entry['file'] as String);
      var source = url;
      if (!kIsWeb) {
        final local = await introCachedPath(id);
        if (local == null) {
          // Not on disk yet (first launch, or a new clip): stream it this
          // once and save it for next time.
          unawaited(introDownload(id, url));
        } else {
          source = Uri.file(local).toString();
        }
      }
      return StartupIntroClip(id: id, source: source, sound: entry['sound'] == true);
    } catch (e) {
      appLogger.w('Startup intro: could not pick a clip', error: e);
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _fetchManifest(SharedPreferences prefs) async {
    try {
      final res = await http
          .get(Uri.parse('${kStartupIntroBase}manifest.json'), headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final manifest = _decode(res.body);
      if (manifest == null) return null;
      await prefs.setString(_prefsKey, res.body);
      if (!kIsWeb) unawaited(_syncCache(manifest));
      return manifest;
    } catch (e) {
      appLogger.d('Startup intro: manifest fetch failed: $e');
      return null;
    }
  }

  /// Downloads clips that are on now or start soon, and deletes ones the
  /// manifest no longer lists.
  static Future<void> _syncCache(Map<String, dynamic> manifest) async {
    final entries = _entries(manifest);
    await introPrune(entries.map((e) => e['id'] as String).toSet());
    final now = DateTime.now();
    for (final e in entries) {
      final soon = List.generate(_prefetchDays + 1, (i) => now.add(Duration(days: i)));
      if (soon.any((d) => _matches(e, d)) && await introCachedPath(e['id'] as String) == null) {
        await introDownload(e['id'] as String, _urlFor(e['file'] as String));
      }
    }
  }

  static Map<String, dynamic>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static final _datePattern = RegExp(r'^(\d{2})-(\d{2})$');

  static List<Map<String, dynamic>> _entries(Map<String, dynamic> manifest) {
    final list = manifest['intros'];
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map<String, dynamic> &&
            e['id'] is String &&
            _idPattern.hasMatch(e['id'] as String) &&
            e['file'] is String &&
            (_isDefault(e) ||
                (e['from'] is String &&
                    e['to'] is String &&
                    _datePattern.hasMatch(e['from'] as String) &&
                    _datePattern.hasMatch(e['to'] as String))))
          e,
    ];
  }

  /// No dates: the always-on default clip.
  static bool _isDefault(Map<String, dynamic> e) => e['from'] == null && e['to'] == null;

  static Map<String, dynamic>? _activeEntry(Map<String, dynamic> manifest, DateTime day) {
    final entries = _entries(manifest);
    for (final e in entries) {
      if (!_isDefault(e) && _matches(e, day)) return e;
    }
    for (final e in entries) {
      if (_isDefault(e)) return e;
    }
    return null;
  }

  static int _mmdd(String s) {
    final m = _datePattern.firstMatch(s)!;
    return int.parse(m.group(1)!) * 100 + int.parse(m.group(2)!);
  }

  static bool _matches(Map<String, dynamic> e, DateTime day) {
    if (_isDefault(e)) return true;
    final d = day.month * 100 + day.day;
    final from = _mmdd(e['from'] as String);
    final to = _mmdd(e['to'] as String);
    return from <= to ? (d >= from && d <= to) : (d >= from || d <= to);
  }

  static String _urlFor(String file) =>
      file.startsWith('http://') || file.startsWith('https://') ? file : '$kStartupIntroBase$file';
}
