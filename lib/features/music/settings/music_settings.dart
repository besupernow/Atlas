import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/audio_quality_preset.dart';
import '../../../navigation/settings_shortcut.dart';
import '../../../screens/settings/settings_screen.dart';
import '../../../screens/settings/settings_utils.dart';
import '../../../services/settings_service.dart';
import '../../../widgets/setting_tile.dart';
import '../../../widgets/settings_page.dart';
import '../../../widgets/settings_section.dart';
import '../data/music_server.dart';
import '../music_strings.dart';
import 'listenbrainz_accounts.dart';

/// Atlas: settings opened from music mode: the shared groups (general, appearance, accounts,
/// downloads, advanced), with music's own groups where video playback would be.
Future<void> openMusicSettings(BuildContext context) =>
    Navigator.of(context).push(buildSettingsRoute(mode: SettingsMode.music, musicSections: musicSettingsSections));

/// Music mode's groups in Settings: playback, and for admins, everyone's ListenBrainz accounts.
List<Widget> musicSettingsSections(BuildContext context) => [
  SettingsGroup(
    title: MusicStrings.settingsMusic,
    children: [
      SettingNavigationTile(
        icon: Symbols.music_note_rounded,
        title: MusicStrings.musicPlayback,
        subtitle: MusicStrings.musicPlaybackSubtitle,
        destinationBuilder: (_) => const MusicPlaybackSettingsScreen(),
      ),
      const _ListenBrainzTile(),
    ],
  ),
];

/// Admins only: which ListenBrainz account goes with each user (saved on the server).
class _ListenBrainzTile extends StatelessWidget {
  const _ListenBrainzTile();

  @override
  Widget build(BuildContext context) {
    if (!MusicServer.isAdmin(context)) return const SizedBox.shrink();
    return SettingNavigationTile(
      icon: Symbols.graphic_eq_rounded,
      title: MusicStrings.listenBrainzAccounts,
      subtitle: MusicStrings.listenBrainzAccountsSubtitle,
      destinationBuilder: (_) => const ListenBrainzAccounts(),
    );
  }
}

/// Atlas: music playback settings (moved here from video playback).
class MusicPlaybackSettingsScreen extends StatelessWidget {
  const MusicPlaybackSettingsScreen({super.key});

  static String _qualityLabel(AudioQualityPreset preset) =>
      preset.isOriginal ? t.videoControls.qualityOriginal : '${preset.bitrateKbps} kbps';

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text(MusicStrings.musicPlayback),
      children: [
        SettingsGroup(
          children: [
            SettingSelectionTile<AudioQualityPreset>(
              pref: SettingsService.musicQualityPreset,
              icon: Symbols.high_quality_rounded,
              title: t.settings.musicQualityTitle,
              subtitleBuilder: _qualityLabel,
              options: AudioQualityPreset.values.map((p) => DialogOption(value: p, title: _qualityLabel(p))).toList(),
            ),
            SettingSwitchTile(
              pref: SettingsService.resumeMusicOnLaunch,
              icon: Symbols.music_history_rounded,
              title: t.settings.resumeMusicOnLaunch,
              subtitle: t.settings.resumeMusicOnLaunchDescription,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
