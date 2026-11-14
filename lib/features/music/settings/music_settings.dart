import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/audio_quality_preset.dart';
import '../../../navigation/settings_shortcut.dart';
import '../../../providers/seerr_account_provider.dart';
import '../../../screens/settings/seerr_settings_screen.dart';
import '../../../screens/settings/settings_screen.dart';
import '../../../screens/settings/settings_utils.dart';
import '../../../services/settings_service.dart';
import '../../../widgets/setting_tile.dart';
import '../../../widgets/settings_page.dart';
import '../../../widgets/settings_section.dart';
import '../discover/listenbrainz.dart';
import '../discover/listenbrainz_connect.dart';
import '../music_strings.dart';

/// Atlas: settings opened from music mode: the shared groups (general, appearance, accounts,
/// downloads, advanced), with music's own groups where video playback would be.
Future<void> openMusicSettings(BuildContext context) =>
    Navigator.of(context).push(buildSettingsRoute(mode: SettingsMode.music, musicSections: musicSettingsSections));

/// Music mode's groups in Settings: playback, ListenBrainz, requests.
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
      const _RequestsTile(),
    ],
  ),
];

class _ListenBrainzTile extends StatelessWidget {
  const _ListenBrainzTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ListenBrainzAccount.changes,
      builder: (context, _, _) {
        final name = ListenBrainzAccount.username(context);
        return SettingNavigationTile(
          icon: Symbols.graphic_eq_rounded,
          title: MusicStrings.listenBrainz,
          subtitle: name == null ? MusicStrings.listenBrainzSubtitle : MusicStrings.connectedAsName(name),
          onTap: () => unawaited(showListenBrainzConnect(context)),
        );
      },
    );
  }
}

class _RequestsTile extends StatelessWidget {
  const _RequestsTile();

  @override
  Widget build(BuildContext context) {
    final SeerrAccountProvider? seerr;
    try {
      seerr = context.watch<SeerrAccountProvider?>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    if (seerr == null) return const SizedBox.shrink();
    final name = seerr.displayName;
    return SettingNavigationTile(
      icon: Symbols.library_add_rounded,
      title: MusicStrings.requestsTitle,
      subtitle: seerr.isConnected
          ? MusicStrings.requestsConnected(name ?? t.services.names.seerr)
          : MusicStrings.requestUnavailable,
      destinationBuilder: (_) => const SeerrSettingsScreen(),
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
