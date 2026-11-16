import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../profiles/profile_activation.dart';
import '../../../profiles/profile_avatar.dart';
import '../../../screens/profile/profile_switch_screen.dart';
import '../../../screens/profile/profile_teardown.dart';
import '../../../utils/dialogs.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/app_menu.dart';
import '../settings/music_settings.dart';

/// Atlas: the profile picture in music mode's header, like the one on the movies Discover
/// page: switch profiles, manage them, ListenBrainz, Settings (music's), sign out.
class MusicProfileButton extends StatefulWidget {
  const MusicProfileButton({super.key});

  @override
  State<MusicProfileButton> createState() => _MusicProfileButtonState();
}

class _MusicProfileButtonState extends State<MusicProfileButton> {
  bool _switching = false;

  Future<void> _onSelected(String value) async {
    if (_switching) return;
    switch (value) {
      case 'settings':
        await openMusicSettings(context);
      case 'manage_profiles':
        await Navigator.of(
          context,
          rootNavigator: true,
        ).push(MaterialPageRoute<void>(builder: (_) => const ProfileSwitchScreen()));
      case 'logout':
        final confirm = await showConfirmDialog(
          context,
          title: t.common.logout,
          message: t.messages.logoutConfirm,
          confirmText: t.common.logout,
          isDestructive: true,
        );
        if (confirm && mounted) await logoutAllProfiles(context);
      default:
        if (!value.startsWith('profile:')) return;
        final id = value.substring('profile:'.length);
        final target = context.read<ActiveProfileProvider>().profiles.where((p) => p.id == id).firstOrNull;
        if (target == null) return;
        setState(() => _switching = true);
        try {
          await switchProfileFromUi(context, target);
        } finally {
          if (mounted) setState(() => _switching = false);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ActiveProfileProvider>();
    final active = profiles.active;
    final theme = Theme.of(context);
    return AppMenuButton<String>(
      enabled: !_switching,
      icon: active != null
          ? ProfileAvatar(profile: active, size: 32, avatarUrl: profiles.avatarUrlFor(active.id))
          : const AppIcon(Symbols.account_circle_rounded, fill: 1, size: 32),
      tooltip: t.profiles.sectionTitle,
      adaptiveSheet: true,
      anchorAlignment: AppMenuAnchorAlignment.end,
      onSelected: (value) => unawaited(_onSelected(value)),
      entriesBuilder: (context) {
        final others = profiles.profiles.where((p) => p.id != active?.id).toList();
        return [
          for (final p in others)
            AppMenuItem<String>(
              value: 'profile:${p.id}',
              leading: ProfileAvatar(profile: p, size: 24, avatarUrl: profiles.avatarUrlFor(p.id)),
              label: p.displayName,
              trailing: p.isPinProtected
                  ? AppIcon(Symbols.lock_rounded, fill: 1, size: 14, color: theme.colorScheme.onSurfaceVariant)
                  : null,
            ),
          if (others.isNotEmpty) const AppMenuDivider(),
          AppMenuItem<String>(value: 'manage_profiles', icon: Symbols.group_rounded, label: t.profiles.sectionTitle),
          AppMenuItem<String>(value: 'settings', icon: Symbols.settings_rounded, label: t.common.settings),
          AppMenuItem<String>(value: 'logout', icon: Symbols.logout_rounded, label: t.common.logout),
        ];
      },
    );
  }
}
