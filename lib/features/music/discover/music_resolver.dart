import '../../../utils/app_logger.dart';
import 'deezer.dart';
import 'discover_models.dart';
import 'music_search_index.dart';
import 'musicbrainz.dart';

/// Atlas: finds the MusicBrainz release group behind an album from Deezer or Last.fm, which is
/// what an Allseerr request (and Lidarr) needs. Codes first, because they name exactly one thing:
///
/// 1. a release group id we already have (MusicBrainz search found it),
/// 2. a release id (Last.fm's album ids) → its group,
/// 3. the album's barcode (Deezer's UPC) → the release with that barcode → its group,
/// 4. a song's ISRC (the song it was found through, or the album's first tracks) → the
///    recording → the release group of that title,
/// 5. and only then the exact title and artist, quoted, with nothing loose accepted.
abstract final class MusicResolver {
  static final Map<String, Future<DiscoverAlbum?>> _resolved = {};

  /// [album] carrying its release group id as [DiscoverAlbum.mbid], or null when nothing ties
  /// it to one. Remembered for the session (misses aren't, so they're tried again).
  static Future<DiscoverAlbum?> releaseGroup(DiscoverAlbum album) {
    if (album.hasMbid) return Future.value(album);
    final key = album.mbid;
    final future = _resolved.putIfAbsent(key, () => _resolve(album));
    return future.then((found) {
      if (found == null) _resolved.remove(key);
      return found;
    });
  }

  static Future<DiscoverAlbum?> _resolve(DiscoverAlbum album) async {
    final steps = <(String, Future<String?> Function())>[
      ('known id', () async => album.ids.releaseGroupMbid),
      ('release id', () => _fromRelease(album)),
      ('barcode', () => _fromBarcode(album)),
      ('ISRC', () => _fromIsrc(album)),
      ('title', () => _fromTitle(album)),
      ('artist releases', () => _fromArtistReleases(album)),
    ];
    Object? failure;
    for (final (name, step) in steps) {
      try {
        final group = await step();
        if (MusicIds.isMbid(group)) {
          appLogger.d('Music: ${album.artistName} - ${album.title} is release group $group (by $name)');
          return album.copyWith(mbid: group, ids: MusicIds(releaseGroupMbid: group));
        }
      } catch (error) {
        if (error is MusicBrainzBusy) failure ??= error;
        appLogger.w('Music: resolving ${album.title} by $name failed', error: error);
      }
    }
    // A step that failed (MusicBrainz busy or unreachable) isn't the same as "not there".
    if (failure != null) throw MusicBrainzBusy(Uri.https('musicbrainz.org'));
    appLogger.w('Music: nothing ties ${album.artistName} - ${album.title} (${album.mbid}) to MusicBrainz');
    return null;
  }

  static Future<String?> _fromRelease(DiscoverAlbum album) async {
    final release = album.ids.releaseMbid;
    if (!MusicIds.isMbid(release)) return null;
    return (await MusicBrainz.release(release!))?.releaseGroupMbid;
  }

  static Future<String?> _fromBarcode(DiscoverAlbum album) async {
    final deezerId = album.deezerId;
    final upc = album.ids.upc ?? (deezerId == null ? null : await Deezer.upcOf(deezerId));
    if (upc == null) return null;
    final releases = await MusicBrainz.releasesForBarcode(upc);
    if (releases.isEmpty) return null;
    // A barcode is one product; prefer the one titled like ours if a code is shared.
    return (_pick(releases, album, requireTitle: true) ?? releases.first).releaseGroupMbid;
  }

  static Future<String?> _fromIsrc(DiscoverAlbum album) async {
    final isrcs = <String>{};
    final known = album.ids.isrc;
    final trackId = album.ids.deezerTrackId;
    final albumId = album.deezerId;
    if (known != null) {
      isrcs.add(known);
    } else if (trackId != null) {
      final isrc = await Deezer.isrcOf(trackId);
      if (isrc != null) isrcs.add(isrc);
    }
    if (isrcs.isEmpty && albumId != null) isrcs.addAll(await Deezer.albumIsrcs(albumId));
    for (final isrc in isrcs) {
      final releases = await MusicBrainz.releasesForIsrc(isrc);
      final match = _pick(releases, album, requireTitle: true) ?? _pickSingle(releases, album);
      if (match != null) return match.releaseGroupMbid;
    }
    return null;
  }

  static Future<String?> _fromTitle(DiscoverAlbum album) async {
    final title = SearchText.cleanTitle(album.title);
    final artist = SearchText.primaryArtist(album.artistName);
    final groups = await MusicBrainz.releaseGroups(artist, title);
    final wantArtist = SearchText.squash(artist);
    final matching = [
      for (final group in groups)
        if (wantArtist.isEmpty || SearchText.squash(group.artistName ?? '').contains(wantArtist)) group,
    ];
    return _pick(matching, album, requireTitle: true)?.releaseGroupMbid;
  }

  /// Last: every release group of the artist on MusicBrainz, matched by title with a slip or
  /// two allowed ("Bang!" vs "BANG", "Pt. 2" vs "Part 2" don't count against it).
  static Future<String?> _fromArtistReleases(DiscoverAlbum album) async {
    final artist = MusicIds.isMbid(album.artistMbid)
        ? album.artistMbid
        : await MusicBrainz.artistId(SearchText.primaryArtist(album.artistName));
    if (artist == null) return null;
    final groups = await MusicBrainz.releaseGroupsOf(artist);
    final exact = _pick(groups, album, requireTitle: true);
    if (exact != null) return exact.releaseGroupMbid;
    final want = _loose(album.title);
    if (want.length < 3) return null;
    final allowed = want.length < 8 ? 1 : 2;
    final close = [
      for (final group in groups)
        if (SearchText.distance(_loose(group.releaseGroupTitle), want) <= allowed) group,
    ];
    return _pick(close, album, requireTitle: false)?.releaseGroupMbid;
  }

  static String _loose(String title) => SearchText.squash(
    SearchText.cleanTitle(title).replaceAll(RegExp(r'\bpart\b', caseSensitive: false), 'pt').replaceAll(RegExp(r'\bvol(ume)?\b', caseSensitive: false), 'vol'),
  );

  /// The release group titled like [album]: the artist's own (not a compilation), the same
  /// kind (single, EP, album) when we know it, the earliest.
  static MbRelease? _pick(List<MbRelease> releases, DiscoverAlbum album, {required bool requireTitle}) {
    final want = SearchText.squash(SearchText.cleanTitle(album.title));
    final candidates = [
      for (final release in releases)
        if (!requireTitle || SearchText.squash(SearchText.cleanTitle(release.releaseGroupTitle)) == want) release,
    ];
    if (candidates.isEmpty) return null;
    final type = album.type?.toLowerCase();
    int rank(MbRelease release) =>
        (release.isOriginal ? 0 : 4) +
        (release.official ? 0 : 2) +
        (type != null && release.primaryType?.toLowerCase() == type ? 0 : 1);
    candidates.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return (a.date ?? '9999').compareTo(b.date ?? '9999');
    });
    return candidates.first;
  }

  /// For a single titled differently on MusicBrainz (listed under its A-side, say): the song's
  /// earliest original single.
  static MbRelease? _pickSingle(List<MbRelease> releases, DiscoverAlbum album) {
    if (album.type?.toLowerCase() != 'single') return null;
    final singles = [
      for (final release in releases)
        if (release.primaryType?.toLowerCase() == 'single' && release.isOriginal) release,
    ]..sort((a, b) => (a.date ?? '9999').compareTo(b.date ?? '9999'));
    return singles.isEmpty ? null : singles.first;
  }
}
