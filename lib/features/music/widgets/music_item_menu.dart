import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../media/ids.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../media/media_server_client.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../utils/dialogs.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/provider_extensions.dart';
import '../../../widgets/app_icon.dart';
import '../data/music_catalog.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import '../discover/music_previews.dart';
import '../discover/music_request_sheet.dart';
import '../music_strings.dart';

/// One action in the menu.
class _Action {
  const _Action(this.icon, this.label, this.run, {this.destructive = false});

  final IconData icon;
  final String label;
  final Future<void> Function(BuildContext context) run;
  final bool destructive;
}

/// Atlas: the long-press / right-click menu for anything in music mode, Apple Music style: the
/// item at the top, then what you'd want to do with it. Things on the server: play, shuffle,
/// play next, add to the queue, start a station, love, add to a playlist, go to the album or
/// artist. Things that aren't: preview, request, see the artist.
///
/// Touch opens a sheet; a right click on desktop opens a menu at the pointer.
abstract final class MusicItemMenu {
  static Future<void> show(BuildContext context, MusicFeedItem item, {Offset? position}) async {
    final actions = _actionsFor(context, item);
    if (actions.isEmpty) return;
    if (position != null && PlatformDetector.isDesktopOS()) {
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
      if (overlay == null) return;
      final chosen = await showMenu<_Action>(
        context: context,
        position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
        items: [
          for (final action in actions)
            PopupMenuItem<_Action>(
              value: action,
              child: Row(
                children: [
                  AppIcon(action.icon, size: 20),
                  const SizedBox(width: 12),
                  Text(action.label),
                ],
              ),
            ),
        ],
      );
      if (chosen != null && context.mounted) await chosen.run(context);
      return;
    }
    final chosen = await showModalBottomSheet<_Action>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _MenuSheet(item: item, actions: actions),
    );
    if (chosen != null && context.mounted) await chosen.run(context);
  }

  static List<_Action> _actionsFor(BuildContext context, MusicFeedItem item) {
    switch (item) {
      case ServerFeedItem(:final item):
        return _serverActions(item);
      case ExternalAlbumItem(:final album):
        return [
          if (MusicPreviews.supported)
            _Action(Symbols.play_circle_rounded, MusicStrings.preview, (c) => previewAlbum(c, album)),
          if (!album.status.onServer && !album.status.inProgress)
            _Action(Symbols.add_circle_rounded, MusicStrings.request, (c) => _request(c, album)),
          _Action(Symbols.album_rounded, MusicStrings.viewDetails, (c) => showAlbumRequestSheet(c, album)),
          if (album.artistName.isNotEmpty)
            _Action(
              Symbols.artist_rounded,
              MusicStrings.goToArtist,
              (c) => showArtistDiscoverySheet(
                c,
                DiscoverArtist(mbid: album.artistMbid ?? 'name:${album.artistName}', name: album.artistName),
              ),
            ),
        ];
      case ExternalArtistItem(:final artist):
        return [_Action(Symbols.artist_rounded, MusicStrings.goToArtist, (c) => showArtistDiscoverySheet(c, artist))];
    }
  }

  static List<_Action> _serverActions(MediaItem item) {
    final isArtist = item.kind == MediaKind.artist;
    final isTrack = item.kind == MediaKind.track;
    final loved = item.isFavorite ?? false;
    return [
      _Action(Symbols.play_arrow_rounded, MusicStrings.play, (c) => _play(c, item)),
      if (!isTrack) _Action(Symbols.shuffle_rounded, MusicStrings.shuffle, (c) => _play(c, item, shuffle: true)),
      _Action(Symbols.playlist_play_rounded, MusicStrings.playNext, (c) => _enqueue(c, item, next: true)),
      _Action(Symbols.queue_music_rounded, MusicStrings.addToQueue, (c) => _enqueue(c, item, next: false)),
      _Action(Symbols.radio_rounded, MusicStrings.startStation, (c) => playInstantMix(c, item)),
      _Action(
        loved ? Symbols.heart_minus_rounded : Symbols.favorite_rounded,
        loved ? MusicStrings.unlove : MusicStrings.love,
        (c) => _setLoved(c, item, !loved),
      ),
      if (!isArtist) _Action(Symbols.playlist_add_rounded, MusicStrings.addToPlaylist, (c) => _addToPlaylist(c, item)),
      if (isTrack && item.parentId != null)
        _Action(Symbols.album_rounded, MusicStrings.goToAlbum, (c) => _openById(c, item, item.parentId!, artist: false)),
      if (!isArtist && (isTrack ? item.grandparentId : item.parentId) != null)
        _Action(
          Symbols.artist_rounded,
          MusicStrings.goToArtist,
          (c) => _openById(c, item, (isTrack ? item.grandparentId : item.parentId)!, artist: true),
        ),
    ];
  }

  static MediaServerClient? _client(BuildContext context, MediaItem item) =>
      context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId));

  static Future<List<MediaItem>> _tracksOf(BuildContext context, MediaItem item) async {
    if (item.kind == MediaKind.track) return [item];
    final client = _client(context, item);
    if (client == null) return const [];
    return item.kind == MediaKind.album ? client.fetchAlbumTracks(item.id) : client.fetchPlayableDescendants(item.id);
  }

  static Future<void> _play(BuildContext context, MediaItem item, {bool shuffle = false}) async {
    await MusicPreviewPlayer.instance.cancel();
    if (!context.mounted) return;
    if (item.kind == MediaKind.track) {
      await playTrackWithAlbumContext(context, item);
      return;
    }
    final tracks = await _tracksOf(context, item);
    if (!context.mounted || tracks.isEmpty) return;
    await playTracks(
      context,
      tracks: tracks,
      shuffle: shuffle,
      playContext: MusicPlayContext(
        title: item.title ?? '',
        kind: item.kind == MediaKind.artist ? MusicPlayContextKind.artist : MusicPlayContextKind.album,
      ),
    );
  }

  static Future<void> _enqueue(BuildContext context, MediaItem item, {required bool next}) async {
    final service = context.read<MusicPlaybackService?>();
    if (service == null) return;
    final tracks = await _tracksOf(context, item);
    if (!context.mounted || tracks.isEmpty) return;
    // Nothing playing yet: just play it.
    if (service.currentTrack == null) {
      await _play(context, item);
      return;
    }
    if (next) {
      service.addNext(tracks);
    } else {
      service.addToEnd(tracks);
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(next ? MusicStrings.willPlayNext : MusicStrings.addedToQueue)),
    );
  }

  static Future<void> _setLoved(BuildContext context, MediaItem item, bool loved) async {
    final client = _client(context, item);
    if (client == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await client.setFavorite(item, loved);
      messenger?.showSnackBar(SnackBar(content: Text(loved ? MusicStrings.loved : MusicStrings.unloved)));
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text(MusicStrings.loadFailed)));
    }
  }

  static Future<void> _addToPlaylist(BuildContext context, MediaItem item) async {
    final client = _client(context, item);
    if (client == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final playlists = await MusicCatalog.of(context).playlists().catchError((Object _) => const []);
    if (!context.mounted) return;
    final mine = [
      for (final playlist in playlists)
        if (playlist.serverId == item.serverId) playlist,
    ];
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const AppIcon(Symbols.add_rounded),
            title: const Text(MusicStrings.newPlaylist),
            onTap: () => Navigator.pop(sheetContext, '_new'),
          ),
          for (final playlist in mine)
            ListTile(
              leading: const AppIcon(Symbols.queue_music_rounded),
              title: Text(playlist.title),
              onTap: () => Navigator.pop(sheetContext, playlist.id),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    final tracks = await _tracksOf(context, item);
    if (tracks.isEmpty || !context.mounted) return;
    try {
      if (choice == '_new') {
        final name = await showTextInputDialog(
          context,
          title: MusicStrings.newPlaylist,
          labelText: MusicStrings.playlistName,
        );
        if (name == null || name.trim().isEmpty) return;
        await client.createPlaylist(title: name.trim(), items: tracks);
      } else {
        await client.addToPlaylist(playlistId: choice, items: tracks);
      }
      messenger?.showSnackBar(const SnackBar(content: Text(MusicStrings.addedToPlaylist)));
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text(MusicStrings.loadFailed)));
    }
  }

  static Future<void> _openById(BuildContext context, MediaItem from, String id, {required bool artist}) async {
    final client = _client(context, from);
    if (client == null) return;
    if (artist) {
      await openArtistById(context, client, id);
      return;
    }
    final album = await client.fetchItem(id).catchError((Object _) => null);
    if (album != null && context.mounted) await navigateToAlbum(context, album);
  }

  static Future<void> _request(BuildContext context, DiscoverAlbum album) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await requestAlbum(context, album);
    messenger?.showSnackBar(SnackBar(content: Text(ok ? MusicStrings.requestSent : MusicStrings.requestFailed)));
  }
}

class _MenuSheet extends StatelessWidget {
  const _MenuSheet({required this.item, required this.actions});

  final MusicFeedItem item;
  final List<_Action> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (String title, String? subtitle) = switch (item) {
      ServerFeedItem(:final item) => (
        item.title ?? '',
        item.kind == MediaKind.track ? item.trackArtistTitle : item.albumArtistTitle,
      ),
      ExternalAlbumItem(:final album) => (album.title, album.artistName),
      ExternalArtistItem(:final artist) => (artist.name, null),
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MusicArt(item: item, size: 64, radius: 10, shadow: false),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (index, action) in actions.indexed) ...[
                  if (index > 0) Divider(height: 1, indent: 56, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                  ListTile(
                    autofocus: index == 0 && PlatformDetector.isTV(),
                    leading: AppIcon(action.icon, fill: 1.0, color: theme.colorScheme.primary),
                    title: Text(action.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    onTap: () => Navigator.pop(context, action),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
