import '../../../media/media_item.dart';
import '../../../services/music/music_bans.dart';

/// Where an album stands for this household: not here, asked for, on its way, or on the server.
/// Mirrors Allseerr's media status (1 unknown … 5 available).
enum DiscoverStatus {
  notRequested,
  requested,
  downloading,
  partial,
  available;

  static DiscoverStatus fromSeerr(Object? status) => switch (status) {
    2 => DiscoverStatus.requested,
    3 => DiscoverStatus.downloading,
    4 => DiscoverStatus.partial,
    5 => DiscoverStatus.available,
    _ => DiscoverStatus.notRequested,
  };

  bool get onServer => this == DiscoverStatus.available || this == DiscoverStatus.partial;
  bool get inProgress => this == DiscoverStatus.requested || this == DiscoverStatus.downloading;
}

/// The standard codes that tie the same music together across Deezer, Last.fm and MusicBrainz.
/// A request needs the MusicBrainz release group; the rest are how we get to it reliably
/// (a UPC or an ISRC names exactly one product or recording, a name only roughly).
class MusicIds {
  const MusicIds({
    this.releaseGroupMbid,
    this.releaseMbid,
    this.recordingMbid,
    this.upc,
    this.isrc,
    this.deezerTrackId,
  });

  /// What Allseerr requests are made with.
  final String? releaseGroupMbid;

  /// One edition of it (Last.fm's album ids are these).
  final String? releaseMbid;

  /// The song this album was found through, when it came from a song.
  final String? recordingMbid;

  /// The barcode of the release (Deezer's albums carry it).
  final String? upc;

  /// The ISRC of the song this album was found through.
  final String? isrc;
  final int? deezerTrackId;

  static const none = MusicIds();

  bool get isEmpty =>
      releaseGroupMbid == null &&
      releaseMbid == null &&
      recordingMbid == null &&
      upc == null &&
      isrc == null &&
      deezerTrackId == null;

  /// Ours, with anything [other] knows that we don't.
  MusicIds merge(MusicIds other) => MusicIds(
    releaseGroupMbid: releaseGroupMbid ?? other.releaseGroupMbid,
    releaseMbid: releaseMbid ?? other.releaseMbid,
    recordingMbid: recordingMbid ?? other.recordingMbid,
    upc: upc ?? other.upc,
    isrc: isrc ?? other.isrc,
    deezerTrackId: deezerTrackId ?? other.deezerTrackId,
  );

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// Whether [value] is a MusicBrainz id (and not one of our `dz:` / `name:` stand-ins).
  static bool isMbid(String? value) => value != null && _uuid.hasMatch(value);
}

/// An album from outside the server (ListenBrainz, MusicBrainz, through Allseerr), keyed by its
/// MusicBrainz release group id, which is also what an Allseerr request is made with.
class DiscoverAlbum {
  const DiscoverAlbum({
    required this.mbid,
    required this.title,
    required this.artistName,
    this.artistMbid,
    this.coverUrl,
    this.releaseDate,
    this.type,
    this.status = DiscoverStatus.notRequested,
    this.reason,
    this.deezerId,
    this.ids = MusicIds.none,
    this.featuring = const [],
  });

  /// Other credited artists ("A & B", or a source's artist list), for clickable names.
  final List<String> featuring;

  /// Everyone credited, for clickable names.
  ArtistCredit get credit => ArtistCredit.parse(artistName, featuring: featuring);

  /// The MusicBrainz release group id, or a stand-in (`dz:<deezer id>`, `lf:…`, `mb:…`) for an
  /// album from Deezer or Last.fm that isn't tied to MusicBrainz yet (see [hasMbid]; requests
  /// resolve it from [ids] first).
  final String mbid;
  final String title;
  final String artistName;
  final String? artistMbid;
  final String? coverUrl;
  final String? releaseDate;

  /// Album, EP, Single…
  final String? type;
  final DiscoverStatus status;

  /// Why it's here ("Because you play Phoebe Bridgers"), when a row explains itself.
  final String? reason;

  /// Deezer's id, for albums from Deezer's charts and releases (art, track list, previews).
  final int? deezerId;

  /// The codes that lead to its MusicBrainz release group.
  final MusicIds ids;

  /// Whether [mbid] is a real MusicBrainz release group id.
  bool get hasMbid => MusicIds.isMbid(mbid);

  String? get year => releaseDate != null && releaseDate!.length >= 4 ? releaseDate!.substring(0, 4) : null;

  DiscoverAlbum copyWith({
    String? mbid,
    DiscoverStatus? status,
    String? coverUrl,
    String? reason,
    int? deezerId,
    String? artistMbid,
    MusicIds? ids,
    String? type,
  }) => DiscoverAlbum(
    mbid: mbid ?? this.mbid,
    title: title,
    artistName: artistName,
    artistMbid: artistMbid ?? this.artistMbid,
    coverUrl: coverUrl ?? this.coverUrl,
    releaseDate: releaseDate,
    type: type ?? this.type,
    status: status ?? this.status,
    reason: reason ?? this.reason,
    deezerId: deezerId ?? this.deezerId,
    ids: ids == null ? this.ids : this.ids.merge(ids),
    featuring: featuring,
  );

  /// From an Allseerr `AlbumResult`.
  static DiscoverAlbum? fromSeerr(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'] as String?;
    final title = json['title'] as String?;
    if (id == null || title == null) return null;
    final media = json['mediaInfo'];
    return DiscoverAlbum(
      mbid: id,
      title: title,
      artistName: json['artistName'] as String? ?? '',
      artistMbid: json['artistId'] as String?,
      coverUrl: _largeCover(json['posterPath'] as String?) ?? coverArtArchiveUrl(id),
      releaseDate: json['releaseDate'] as String?,
      type: json['albumType'] as String?,
      status: DiscoverStatus.fromSeerr(media is Map ? media['status'] : null),
    );
  }

  /// The Cover Art Archive's front cover for a release group (redirects to the image).
  static String coverArtArchiveUrl(String releaseGroupMbid, {int size = 500}) =>
      'https://coverartarchive.org/release-group/$releaseGroupMbid/front-$size';

  /// ListenBrainz hands out 250px thumbnails; ask the archive for the 500px one instead.
  static String? _largeCover(String? url) => url?.replaceFirst('_thumb250.jpg', '_thumb500.jpg');
}

/// An artist from outside the server.
class DiscoverArtist {
  const DiscoverArtist({
    required this.mbid,
    required this.name,
    this.imageUrl,
    this.backdropUrl,
    this.reason,
    this.deezerId,
  });

  /// The MusicBrainz artist id, or `dz:<deezer id>` for an artist from Deezer.
  final String mbid;
  final String name;
  final String? imageUrl;
  final String? backdropUrl;
  final String? reason;
  final int? deezerId;

  bool get hasMbid => MusicIds.isMbid(mbid);

  static DiscoverArtist? fromSeerr(Object? json, {String? reason}) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'] as String?;
    final name = json['name'] as String?;
    if (id == null || name == null) return null;
    return DiscoverArtist(
      mbid: id,
      name: name,
      imageUrl: json['artistThumb'] as String?,
      backdropUrl: json['artistBackdrop'] as String?,
      reason: reason,
    );
  }
}

/// One song of an album's track list.
class DiscoverTrack {
  const DiscoverTrack({
    required this.title,
    required this.number,
    this.length,
    this.disc = 1,
    this.artist,
    this.previewUrl,
    this.isrc,
    this.deezerId,
  });

  final String title;
  final String number;

  /// The song's ISRC and Deezer id, when Deezer gave them (for requesting just this song).
  final String? isrc;
  final int? deezerId;
  final Duration? length;

  /// A 30-second clip (Deezer), when there is one.
  final String? previewUrl;
  final int disc;
  final String? artist;
}

/// Everything the request sheet shows about an album.
class DiscoverAlbumDetails {
  const DiscoverAlbumDetails({
    required this.album,
    required this.tracks,
    this.genres = const [],
    this.artistImageUrl,
    this.artistBackdropUrl,
    this.about,
  });

  final DiscoverAlbum album;
  final List<DiscoverTrack> tracks;
  final List<String> genres;
  final String? artistImageUrl;
  final String? artistBackdropUrl;
  final String? about;
}

/// One card in a music row: something on the server, an album that isn't (yet), or an artist
/// that isn't.
/// Atlas: whether this person has hidden it (or its album, or its artist).
extension MusicFeedItemBans on MusicFeedItem {
  bool get isHidden => switch (this) {
    ServerFeedItem(:final item) => MusicBans.instance.blocks(item),
    ExternalAlbumItem(:final album) => MusicBans.instance.blocksNames(
      artist: album.artistName,
      album: album.title,
      featuring: album.featuring,
    ),
    ExternalArtistItem(:final artist) => MusicBans.instance.blocksNames(artist: artist.name),
  };
}

sealed class MusicFeedItem {
  const MusicFeedItem();

  /// Stable id for focus memory and dedupe.
  String get key;
}

final class ServerFeedItem extends MusicFeedItem {
  const ServerFeedItem(this.item, {this.reason});

  final MediaItem item;
  final String? reason;

  @override
  String get key => 'server:${item.globalKey}';
}

final class ExternalAlbumItem extends MusicFeedItem {
  const ExternalAlbumItem(this.album);

  final DiscoverAlbum album;

  @override
  String get key => 'album:${album.mbid}';
}

final class ExternalArtistItem extends MusicFeedItem {
  const ExternalArtistItem(this.artist);

  final DiscoverArtist artist;

  @override
  String get key => 'artist:${artist.mbid}';
}

/// Who's on a song or album: the main artist(s) and anyone featured.
class ArtistCredit {
  const ArtistCredit(this.main, [this.featured = const []]);

  final List<String> main;
  final List<String> featured;

  List<String> get all => [...main, ...featured];
  bool get isEmpty => main.isEmpty && featured.isEmpty;

  static final _featInTitle = RegExp(r'[(\[]\s*(?:feat\.?|ft\.?|featuring|with)\s+([^)\]]+)[)\]]', caseSensitive: false);
  static final _featInName = RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\s+', caseSensitive: false);

  /// From a credit like "Drake feat. Future" and a title like "Song (feat. X & Y)". Main credits
  /// aren't split on "&" or "and" (Simon & Garfunkel), featured lists are.
  static ArtistCredit parse(String credit, {String? title, List<String> featuring = const []}) {
    final parts = credit.split(_featInName);
    final main = _joinedNames(parts.first);
    final featured = <String>[
      for (final part in parts.skip(1)) ..._list(part),
      for (final name in featuring) name.trim(),
      if (title != null)
        for (final match in _featInTitle.allMatches(title)) ..._list(match.group(1) ?? ''),
    ];
    final seen = {for (final name in main) name.toLowerCase()};
    return ArtistCredit(main, [
      for (final name in featured)
        if (name.isNotEmpty && seen.add(name.toLowerCase())) name,
    ]);
  }

  /// Jellyfin joins a track's artists with ", "; keep "Tyler, The Creator" whole.
  static List<String> _joinedNames(String value) {
    final pieces = value.split(', ');
    final names = <String>[];
    for (final piece in pieces) {
      if (names.isNotEmpty && piece.startsWith('The ')) {
        names[names.length - 1] = '${names.last}, $piece';
      } else if (piece.trim().isNotEmpty) {
        names.add(piece.trim());
      }
    }
    return names.isEmpty ? [value.trim()] : names;
  }

  static List<String> _list(String value) =>
      value.split(RegExp(r'\s*(?:,|&|\band\b)\s*')).map((name) => name.trim()).where((name) => name.isNotEmpty).toList();
}
