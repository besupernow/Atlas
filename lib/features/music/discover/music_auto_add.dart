import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../profiles/active_profile_provider.dart';
import '../../../services/music/music_bans.dart';
import '../../../services/settings_service.dart';
import '../../../utils/app_logger.dart';
import 'allseerr_music.dart';
import 'discover_feed.dart';
import 'discover_models.dart';
import 'listenbrainz.dart';

/// Atlas: grows the library from each person's ListenBrainz listening, by asking Allseerr
/// (which hands it to Lidarr) for albums they're likely to play. It runs for whoever is using
/// the app, as them, so the requests show up under their name.
///
/// **Pace.** Someone new to Atlas has an empty-feeling library, so early on it adds more
/// (up to [_startPerWeek] albums a week, leaning on the albums they already love), then
/// halves that every [_halfLife] until it settles at [_floorPerWeek]. On top of the age
/// curve, it watches what happened to what it added: albums it asked for that got listened
/// to keep the pace up, albums nobody played slow it down, and if a run of them went
/// unplayed it stops until they play one.
///
/// **Not overflowing the server.**
/// * Only for people who are listening (something scrobbled lately).
/// * At most [_perRun] albums in one go and one look every few hours, so it trickles.
/// * Holds off while its recent requests are still downloading (Lidarr behind or stuck).
/// * Albums and EPs only: no singles, compilations, live albums, remixes or soundtracks.
/// * Never anything hidden, already on the server, already requested, or that it asked for
///   before (so an album someone deleted doesn't come back).
abstract final class MusicAutoAdd {
  /// The weekly pace for someone brand new.
  static const _startPerWeek = 10;

  /// Where the pace settles.
  static const _floorPerWeek = 1;

  /// How long it takes the pace to halve.
  static const _halfLife = Duration(days: 21);

  /// The most it asks for in one run.
  static const _perRun = 3;

  /// How long an added album gets before it's judged played or not.
  static const _judgeAfter = Duration(days: 14);

  /// This many unplayed picks in a row (with none played) pauses it.
  static const _pauseAfterMisses = 5;

  static const _activeWithin = Duration(days: 10);

  /// New people may have listened elsewhere a while back; give them longer.
  static const _activeWithinNew = Duration(days: 45);

  static final Map<String, Future<void>> _running = {};

  static StringPref _ledgerPref(String profile) => StringPref('atlas_music_auto_add_$profile');

  /// Looks for something to add, if it's on, it's time, and the person qualifies. Safe to
  /// call often (on opening music mode); it does nothing most of the time.
  static Future<void> maybeRun(BuildContext context) {
    if (!SettingsService.instance.read(SettingsService.musicAutoAdd)) return Future.value();
    final String? active;
    try {
      active = context.read<ActiveProfileProvider>().activeId;
    } on ProviderNotFoundException {
      return Future.value();
    }
    if (active == null) return Future.value();
    // A non-null copy: the closure below can't rely on [active] staying promoted.
    final String profile = active;
    final username = ListenBrainzAccount.username(context);
    final allseerr = AllseerrMusic.of(context);
    if (username == null || allseerr == null) return Future.value();
    final discovery = MusicDiscovery.of(context);
    return _running.putIfAbsent(profile, () async {
      try {
        await _run(profile, ListenBrainz(username), allseerr, discovery);
      } catch (error, stack) {
        appLogger.w('Music auto-add: skipped this time', error: error, stackTrace: stack);
      } finally {
        _running.remove(profile);
      }
    });
  }

  /// The age curve alone: [_startPerWeek] halving every [_halfLife], never under the floor.
  @visibleForTesting
  static double basePace(Duration age) {
    final halvings = age.inHours / _halfLife.inHours;
    return math.max(_floorPerWeek.toDouble(), _startPerWeek * math.pow(0.5, halvings).toDouble());
  }

  /// How the picks it already made are doing: scales the pace (0 pauses it).
  @visibleForTesting
  static double engagement({required int judged, required int played, required int missesInARow}) {
    if (judged < 3) return 1; // Too early to tell.
    if (played == 0 && missesInARow >= _pauseAfterMisses) return 0;
    final rate = played / judged;
    if (rate >= 0.7) return 1.4;
    if (rate >= 0.4) return 1;
    if (rate >= 0.2) return 0.6;
    return 0.35;
  }

  static Future<void> _run(String profile, ListenBrainz listenBrainz, AllseerrMusic allseerr, MusicDiscovery discovery) async {
    final ledger = _Ledger.read(_ledgerPref(profile));
    final now = DateTime.now();
    ledger.startedAt ??= now;
    final age = now.difference(ledger.startedAt!);
    final isNew = age < const Duration(days: 28);
    // Looks more often while it's building the library up.
    final cooldown = isNew ? const Duration(hours: 4) : const Duration(hours: 12);
    if (ledger.lastRun != null && now.difference(ledger.lastRun!) < cooldown) return;
    ledger.lastRun = now;
    await ledger.save();

    final user = listenBrainz.username;
    final last = await listenBrainz.lastListenedAt();
    if (last == null || now.difference(last) > (isNew ? _activeWithinNew : _activeWithin)) {
      appLogger.d('Music auto-add: $user hasn\'t listened lately, nothing to add');
      return;
    }

    // What became of earlier picks: played (in their ListenBrainz stats) or not.
    final listened = await listenBrainz.topReleaseGroups(count: 200, range: 'quarter');
    final playedIds = {for (final group in listened) group.mbid};
    final playedNames = {for (final group in listened) _key(group.artist, group.title)};
    ledger.judge(now, (id, entry) => playedIds.contains(id) || playedNames.contains(_key(entry.artist, entry.title)));
    final (:judged, :played, :missesInARow) = ledger.results();
    final factor = engagement(judged: judged, played: played, missesInARow: missesInARow);
    final pace = basePace(age) * factor;
    if (pace <= 0) {
      appLogger.i('Music auto-add: paused for $user ($missesInARow picks in a row went unplayed)');
      await ledger.save();
      return;
    }

    // This week's budget: the pace, minus what it (and they) already asked for.
    final known = await discovery.known();
    final weekAgo = now.subtract(const Duration(days: 7));
    var budget = pace.round() - ledger.addedSince(weekAgo);
    // Hold off while its earlier picks are still on their way (downloads behind or stuck).
    // (Only the last month's: something Lidarr never finds shouldn't block it forever.)
    final waiting = ledger.addedIdsSince(now.subtract(const Duration(days: 30))).where((id) => known[id]?.inProgress ?? false).length;
    if (waiting >= math.max(3, pace.ceil())) {
      appLogger.d('Music auto-add: $waiting picks for $user still downloading; waiting');
      await ledger.save();
      return;
    }
    budget = math.min(budget, _perRun);
    if (budget <= 0) {
      await ledger.save();
      return;
    }

    final candidates = await _candidates(listenBrainz, isNew: isNew, playedIds: playedIds);
    final seen = <String>{};
    var asked = 0;
    for (final (:album, :reason) in candidates) {
      if (asked >= budget) break;
      final id = album.releaseGroupMbid;
      if (!seen.add(id) || ledger.has(id) || known.containsKey(id) || playedIds.contains(id)) continue;
      if (!_isAlbumOrEp(album.type) || _looksLikeExtra(album.title)) continue;
      if (MusicBans.instance.blocksNames(artist: album.artistName, album: album.title)) continue;
      final discover = album.toDiscover();
      if (await discovery.serverCopy(discover) != null) {
        ledger.mark(id, now, album, added: false); // Already here; don't look at it again.
        continue;
      }
      try {
        final status = await allseerr.request(discover);
        ledger.mark(id, now, album, added: true);
        asked++;
        appLogger.i('Music auto-add: asked for "${album.title}" by ${album.artistName} for $user '
            '($reason; pace ${pace.toStringAsFixed(1)}/week) → ${status.name}');
      } catch (error) {
        // Not available, no match, or refused: don't keep trying it.
        ledger.mark(id, now, album, added: false);
        appLogger.d('Music auto-add: couldn\'t ask for "${album.title}"', error: error);
      }
    }
    await ledger.save();
    if (asked > 0) MusicDiscovery.invalidate();
  }

  /// Best bets first. Early on it leans on what the person already loves (the best-known
  /// albums of their most played artists ever), so the library fills with music they'll
  /// recognize; after that, new albums from artists they play a lot right now, then
  /// albums ListenBrainz recommends several of their songs from.
  static Future<List<({ListenBrainzAlbum album, String reason})>> _candidates(
      ListenBrainz listenBrainz, {
        required bool isNew,
        required Set<String> playedIds,
      }) async {
    final list = <({ListenBrainzAlbum album, String reason})>[];

    if (isNew) {
      final favorites = await listenBrainz.topArtists(count: 15, range: 'all_time');
      for (final artist in favorites) {
        try {
          final albums = await ListenBrainz.popularAlbums(artist.mbid, artistName: artist.name);
          // Their two best-known albums they haven't been playing from ListenBrainz's stats.
          var taken = 0;
          for (final album in albums) {
            if (taken >= 2) break;
            if (!_isAlbumOrEp(album.type) || playedIds.contains(album.releaseGroupMbid)) continue;
            list.add((album: album, reason: 'a favorite artist\'s best-known album'));
            taken++;
          }
        } catch (error) {
          appLogger.d('Music auto-add: no popular albums for ${artist.name}', error: error);
        }
      }
    }

    final top = await listenBrainz.topArtists(count: 10);
    final topIds = {for (final artist in top) artist.mbid};
    final fresh = await listenBrainz.freshReleases(days: 21);
    list.addAll([
      for (final album in fresh)
        if (album.artistMbid != null && topIds.contains(album.artistMbid))
          (album: album, reason: 'new from an artist they play a lot'),
    ]);

    final recommended = await listenBrainz.recommendedAlbums(recordings: 200);
    // Early on one strong recommendation is enough; later it takes a few songs from it.
    final minHits = isNew ? 1 : 2;
    final sure = recommended.where((album) => album.hits >= minHits).toList()
      ..sort((a, b) => b.hits != a.hits ? b.hits.compareTo(a.hits) : b.score.compareTo(a.score));
    list.addAll([for (final album in sure) (album: album, reason: '${album.hits} recommended songs on it')]);
    return list;
  }

  static String _key(String artist, String title) => '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';

  static bool _isAlbumOrEp(String? type) {
    final value = (type ?? 'Album').toLowerCase();
    return value == 'album' || value == 'ep';
  }

  /// Titles that are usually not the album people mean (unknown types sneak through).
  static final _extra = RegExp(
    r'\b(live|remix(es)?|remixed|instrumentals?|karaoke|acoustic versions|greatest hits|best of|anniversary|demos?|sessions)\b',
    caseSensitive: false,
  );

  static bool _looksLikeExtra(String title) => _extra.hasMatch(title);
}

/// One thing auto-add looked at for a person.
class _Entry {
  _Entry({required this.at, required this.added, this.artist = '', this.title = '', this.played});

  final DateTime at;
  final bool added;
  final String artist;
  final String title;

  /// Null until it's been long enough to judge; then whether it got listened to.
  bool? played;
}

/// What auto-add asked for (and passed over) for one person, so it never asks twice, can
/// keep count of the week, and can tell whether its picks get played.
class _Ledger {
  _Ledger(this._pref, this.startedAt, this.lastRun, this._entries);

  final StringPref _pref;

  /// When it first ran for this person (the pace curve starts here).
  DateTime? startedAt;
  DateTime? lastRun;

  /// Release group → what happened.
  final Map<String, _Entry> _entries;

  static _Ledger read(StringPref pref) {
    try {
      final raw = SettingsService.instance.read(pref);
      if (raw.isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final entries = <String, _Entry>{};
        final items = json['items'];
        if (items is Map) {
          for (final MapEntry(:key, :value) in items.entries) {
            if (key is String && value is Map && value['at'] is String) {
              entries[key] = _Entry(
                at: DateTime.parse(value['at'] as String),
                added: value['added'] == true,
                artist: value['artist'] as String? ?? '',
                title: value['title'] as String? ?? '',
                played: value['played'] as bool?,
              );
            }
          }
        }
        DateTime? date(Object? value) => value is String ? DateTime.tryParse(value) : null;
        final last = date(json['lastRun']);
        // Ledgers from before the pace existed: start the curve at their oldest entry.
        final oldest = entries.values.map((entry) => entry.at).fold<DateTime?>(
          null,
              (oldest, at) => oldest == null || at.isBefore(oldest) ? at : oldest,
        );
        return _Ledger(pref, date(json['startedAt']) ?? oldest ?? last, last, entries);
      }
    } catch (_) {
      // Start over.
    }
    return _Ledger(pref, null, null, {});
  }

  bool has(String id) => _entries.containsKey(id);

  Iterable<String> addedIdsSince(DateTime since) => _entries.entries
      .where((entry) => entry.value.added && entry.value.at.isAfter(since))
      .map((entry) => entry.key);

  int addedSince(DateTime since) => _entries.values.where((entry) => entry.added && entry.at.isAfter(since)).length;

  void mark(String id, DateTime at, ListenBrainzAlbum album, {required bool added}) =>
      _entries[id] = _Entry(at: at, added: added, artist: album.artistName, title: album.title);

  /// Settles played-or-not for picks old enough to judge. Once played, always played.
  void judge(DateTime now, bool Function(String id, _Entry entry) wasPlayed) {
    for (final MapEntry(:key, :value) in _entries.entries) {
      if (!value.added || value.played == true) continue;
      if (wasPlayed(key, value)) {
        value.played = true;
      } else if (now.difference(value.at) >= MusicAutoAdd._judgeAfter) {
        value.played = false;
      }
    }
  }

  /// How the judged picks went, and how many of the latest ones in a row went unplayed.
  ({int judged, int played, int missesInARow}) results() {
    final judged = _entries.values.where((entry) => entry.added && entry.played != null).toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    var misses = 0;
    for (final entry in judged) {
      if (entry.played == true) break;
      misses++;
    }
    // Only the last 20 count, so old history doesn't drag on forever.
    final recent = judged.take(20).toList();
    return (judged: recent.length, played: recent.where((entry) => entry.played == true).length, missesInARow: misses);
  }

  Future<void> save() async {
    // Passed-over albums are forgotten after a year (things change); requested ones never.
    final cutoff = DateTime.now().subtract(const Duration(days: 365));
    _entries.removeWhere((_, entry) => !entry.added && entry.at.isBefore(cutoff));
    final json = {
      'startedAt': startedAt?.toIso8601String(),
      'lastRun': lastRun?.toIso8601String(),
      'items': {
        for (final MapEntry(:key, :value) in _entries.entries)
          key: {
            'at': value.at.toIso8601String(),
            'added': value.added,
            if (value.artist.isNotEmpty) 'artist': value.artist,
            if (value.title.isNotEmpty) 'title': value.title,
            if (value.played != null) 'played': value.played,
          },
      },
    };
    await SettingsService.instance.write(_pref, jsonEncode(json));
  }
}
