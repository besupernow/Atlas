import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../settings_service.dart';

/// Atlas: what this person listened to before the current queue, kept per profile and across
/// restarts, so starting something new (playing one song, an album, a station) never wipes
/// History the way it used to. The queue's own already-played songs sit on top of this.
class MusicHistory extends ChangeNotifier {
  MusicHistory._();

  static final MusicHistory instance = MusicHistory._();

  /// How far back it remembers.
  static const int limit = 200;

  String? _profile;
  List<MediaItem> _items = const [];
  Timer? _saveTimer;

  /// Oldest first.
  List<MediaItem> get items => _items;

  /// The profile this is for (null before anyone's signed in).
  String? get profile => _profile;

  static StringPref _pref(String profile) => StringPref('atlas_music_history_$profile');

  void useProfile(String? profile) {
    if (profile == _profile) return;
    _flush();
    _profile = profile;
    var items = <MediaItem>[];
    if (profile != null) {
      try {
        final raw = SettingsService.instance.read(_pref(profile));
        if (raw.isNotEmpty) {
          final list = jsonDecode(raw);
          if (list is List) {
            for (final entry in list) {
              if (entry is Map<String, dynamic>) items.add(MediaItem.fromJson(entry));
            }
          }
        }
      } catch (error) {
        appLogger.w('Music: reading history failed', error: error);
      }
    }
    _items = items;
    notifyListeners();
  }

  /// Songs that finished being the queue (oldest first) go on the end.
  void add(List<MediaItem> played) {
    if (played.isEmpty) return;
    final next = [..._items, ...played];
    _items = next.length > limit ? next.sublist(next.length - limit) : next;
    _scheduleSave();
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _items.length) return;
    _items = [..._items]..removeAt(index);
    _scheduleSave();
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items = const [];
    _scheduleSave();
    notifyListeners();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _flush);
  }

  void _flush() {
    final pending = _saveTimer?.isActive ?? false;
    _saveTimer?.cancel();
    _saveTimer = null;
    final profile = _profile;
    if (!pending || profile == null) return;
    final json = jsonEncode([for (final item in _items) item.toJson()]);
    unawaited(
      SettingsService.instance.write(_pref(profile), json).catchError((Object error) {
        appLogger.w('Music: saving history failed', error: error);
      }),
    );
  }
}
