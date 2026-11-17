import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../services/music/music_bans.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/settings_page.dart';
import '../../../widgets/settings_section.dart';
import '../music_strings.dart';

/// Atlas: what this person hid from music mode, to bring any of it back.
class HiddenMusicScreen extends StatelessWidget {
  const HiddenMusicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: MusicBans.instance,
      builder: (context, _) {
        final bans = MusicBans.instance.bans.reversed.toList();
        return SettingsPage(
          title: const Text(MusicStrings.hiddenMusic),
          children: [
            if (bans.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  MusicStrings.hiddenMusicEmpty,
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else
              SettingsGroup(
                title: MusicStrings.hiddenMusicSubtitle,
                children: [
                  for (final ban in bans)
                    ListTile(
                      leading: AppIcon(switch (ban.kind) {
                        MusicBanKind.artist => Symbols.artist_rounded,
                        MusicBanKind.album => Symbols.album_rounded,
                        MusicBanKind.song => Symbols.music_note_rounded,
                      }),
                      title: Text(ban.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(switch (ban.kind) {
                        MusicBanKind.artist => MusicStrings.hiddenArtist,
                        MusicBanKind.album => MusicStrings.hiddenAlbumBy(ban.artist),
                        MusicBanKind.song => MusicStrings.hiddenSongBy(ban.artist),
                      }),
                      trailing: TextButton(
                        onPressed: () => unawaited(MusicBans.instance.remove(ban)),
                        child: const Text(MusicStrings.unhide),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
