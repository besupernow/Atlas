import 'media_item.dart';

/// Release-format sections of an artist's discography, mirroring how Plex's
/// own clients split an artist's music library into Albums, Singles & EPs,
/// Live, and Compilations. Declaration order is display order.
enum DiscographyGroupKind { albums, singlesAndEps, live, compilations }

/// One discography section: a [kind] plus the albums it contains, in server
/// order (newest first).
class ArtistDiscographyGroup {
  final DiscographyGroupKind kind;
  final List<MediaItem> items;

  const ArtistDiscographyGroup({required this.kind, required this.items});
}

/// Partitions [albums] into ordered discography sections using the per-album
/// [kindOf] classification. Album order is preserved within each section,
/// sections appear in [DiscographyGroupKind] declaration order, and empty
/// sections are dropped.
List<ArtistDiscographyGroup> buildArtistDiscographyGroups(
    List<MediaItem> albums,
    DiscographyGroupKind Function(MediaItem album) kindOf,
    ) {
  final buckets = {for (final kind in DiscographyGroupKind.values) kind: <MediaItem>[]};
  for (final album in albums) {
    buckets[kindOf(album)]!.add(album);
  }
  return [
    for (final kind in DiscographyGroupKind.values)
      if (buckets[kind]!.isNotEmpty) ArtistDiscographyGroup(kind: kind, items: buckets[kind]!),
  ];
}

/// Atlas: release type from an album's shape, for backends whose items carry no release-type
/// tag (Jellyfin/Emby). The title is checked first ("Live at...", "Greatest Hits", "- Single",
/// "EP"), then the track count and running time: up to 3 tracks, or under 12 minutes, is a
/// single; up to 6 tracks under 30 minutes is an EP. Anything without enough to go on stays an
/// album.
DiscographyGroupKind classifyReleaseByShape(MediaItem album) {
  final title = (album.title ?? '').toLowerCase();
  if (_liveTitle.hasMatch(title)) return DiscographyGroupKind.live;
  if (_compilationTitle.hasMatch(title)) return DiscographyGroupKind.compilations;
  if (_singleOrEpTitle.hasMatch(title)) return DiscographyGroupKind.singlesAndEps;

  final tracks = album.childCount ?? album.leafCount;
  final minutes = album.durationMs == null ? null : album.durationMs! / 60000;
  if (tracks != null && tracks > 0) {
    if (tracks <= 3) return DiscographyGroupKind.singlesAndEps;
    if (tracks <= 6 && (minutes == null || minutes < 30)) return DiscographyGroupKind.singlesAndEps;
  } else if (minutes != null && minutes > 0 && minutes < 12) {
    return DiscographyGroupKind.singlesAndEps;
  }
  return DiscographyGroupKind.albums;
}

final _liveTitle = RegExp(r'\b(live at|live in|live from|unplugged|in concert)\b|\(live\)|\[live\]|- live$');
final _compilationTitle = RegExp(r'\b(greatest hits|best of|the very best|anthology|essentials|the collection)\b');
final _singleOrEpTitle = RegExp(r'(\s-\s|\(|\[)\s*(single|ep)\s*(\)|\])?$|\bep\b');
